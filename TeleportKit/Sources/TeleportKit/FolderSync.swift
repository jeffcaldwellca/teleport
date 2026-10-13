import Foundation

// One-way folder sync: bring a destination folder in line with a source
// folder by transferring only what differs. This file is the planning half —
// it decides what to do and changes nothing. Executing a plan is up to the
// caller (the app runs it through its transfer queue; tport runs it directly).

/// A file or folder found while scanning one side, identified by its path
/// relative to the folder being synced (`css/site.css`).
public struct SyncEntry: Equatable, Sendable {
    public var relativePath: String
    public var isDirectory: Bool
    public var size: Int64?
    public var modified: Date?
    /// False when the time is only known to the minute (FTP servers that
    /// offer nothing better than `LIST`).
    public var modifiedHasSeconds: Bool
    /// Something that is there but is neither looked into nor touched: a
    /// symbolic link. Whatever sits under the same name on the other side is
    /// left alone too.
    public var isOpaque: Bool

    public init(relativePath: String, isDirectory: Bool, size: Int64? = nil,
                modified: Date? = nil, modifiedHasSeconds: Bool = true, isOpaque: Bool = false) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.modifiedHasSeconds = modifiedHasSeconds
        self.isOpaque = isOpaque
    }
}

public enum SyncDirection: String, CaseIterable, Sendable {
    /// Local is the source; the remote folder is brought in line with it.
    case upload
    /// Remote is the source; the local folder is brought in line with it.
    case download
}

public struct SyncOptions: Sendable {
    /// Delete what exists only at the destination.
    public var deleteExtraneous: Bool
    /// Compare sizes only, for servers whose clocks can't be trusted.
    public var sizeOnly: Bool
    /// Glob patterns for paths to ignore on both sides (see `FolderSync.matches`).
    public var excludes: [String]
    /// Permit deleting everything at the destination because the source is empty.
    public var allowEmptySource: Bool

    public init(deleteExtraneous: Bool = false, sizeOnly: Bool = false,
                excludes: [String] = [], allowEmptySource: Bool = false) {
        self.deleteExtraneous = deleteExtraneous
        self.sizeOnly = sizeOnly
        self.excludes = excludes
        self.allowEmptySource = allowEmptySource
    }
}

public struct SyncAction: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Copy the file from the source to the destination.
        case transfer
        /// Create this folder at the destination.
        case createDirectory
        /// Remove this file or (by then empty) folder from the destination.
        case delete
        /// Deliberately left alone; `reason` says why.
        case skip
    }

    public var relativePath: String
    public var kind: Kind
    public var isDirectory: Bool
    public var size: Int64?
    /// Why, in a few words fit for showing to the user ("new", "size differs").
    public var reason: String
}

public struct SyncPlan: Equatable, Sendable {
    public var direction: SyncDirection
    /// In execution order: folders to create (parents first), transfers,
    /// deletions (deepest first), then anything skipped.
    public var actions: [SyncAction]
    /// Same-size files whose remote time is too imprecise to compare (see
    /// `FolderSync.refine`). Empty once refined.
    public var uncertain: [String] = []

    public var directories: [SyncAction] { actions.filter { $0.kind == .createDirectory } }
    public var transfers: [SyncAction] { actions.filter { $0.kind == .transfer } }
    public var deletions: [SyncAction] { actions.filter { $0.kind == .delete } }
    public var skips: [SyncAction] { actions.filter { $0.kind == .skip } }
    public var totalBytes: Int64 { transfers.reduce(0) { $0 + ($1.size ?? 0) } }
    /// False when the two sides are already in sync (skips aside).
    public var hasChanges: Bool { actions.contains { $0.kind != .skip } }
}

public enum FolderSyncError: LocalizedError, Equatable {
    case emptySourceWithDeletion
    case sourceMissing(String)
    case tooLarge(limit: Int)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .emptySourceWithDeletion:
            return "The source folder is empty, so syncing with deletion on would remove everything at the " +
                   "destination. If that is really what you want, allow an empty source explicitly."
        case .sourceMissing(let path):
            return "The folder \(path) doesn't exist."
        case .tooLarge(let limit):
            return "The folder contains more than \(limit) items. Sync it in smaller pieces."
        case .unreadable(let path):
            return "\(path) couldn\u{2019}t be read, so the folders can\u{2019}t be compared safely. " +
                   "Nothing was changed."
        }
    }
}

public enum FolderSync {

    /// Most entries a side may have.
    public static let defaultLimit = 10_000

    /// Always ignored, on both sides: Finder's metadata, and the staging
    /// files of downloads that are still in flight.
    public static let builtInExcludes = [".DS_Store", "*.part"]

    /// A same-size pair whose remote time is only known to the minute can't
    /// be judged when the two times are this close: such listings (FTP
    /// `LIST`) are also in the server's own time zone, up to 14 hours off.
    static let timeZoneReach: TimeInterval = 15 * 3600

    /// Seconds a source may be "newer" by before it counts: file systems and
    /// protocols round times differently.
    static let tolerance: TimeInterval = 2
    /// The same, when one side's time is only known to the minute.
    static let coarseTolerance: TimeInterval = 60

    // MARK: - Planning

    public static func plan(
        local: [SyncEntry], remote: [SyncEntry],
        direction: SyncDirection, options: SyncOptions = SyncOptions()
    ) throws -> SyncPlan {
        let patterns = builtInExcludes + options.excludes
        func isExcluded(_ entry: SyncEntry) -> Bool {
            patterns.contains { matches(exclude: $0, relativePath: entry.relativePath) }
        }
        /// Names that are one and the same on a case-insensitive file system.
        func fold(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

        let allSource = direction == .upload ? local : remote
        let allDestination = direction == .upload ? remote : local
        let source = allSource.filter { !isExcluded($0) && !$0.isOpaque }
        let destination = allDestination.filter { !isExcluded($0) && !$0.isOpaque }

        if options.deleteExtraneous, source.isEmpty, !options.allowEmptySource {
            throw FolderSyncError.emptySourceWithDeletion
        }

        let sourceByPath = Dictionary(source.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let destinationByPath = Dictionary(destination.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        // --- Paths that are left alone, with everything beneath them, on both sides.
        // Each is recorded case-folded, with why and how to show it.
        var untouchable: [String: (path: String, isDirectory: Bool, reason: String?)] = [:]

        // A file on one side where the other has a folder: replacing either
        // would destroy something.
        for entry in source {
            guard let other = destinationByPath[entry.relativePath], other.isDirectory != entry.isDirectory else { continue }
            let (here, there) = direction == .upload ? ("locally", "on the server") : ("on the server", "locally")
            untouchable[fold(entry.relativePath)] = (
                entry.relativePath, entry.isDirectory,
                entry.isDirectory ? "a folder \(here) but a file \(there)" : "a file \(here) but a folder \(there)"
            )
        }

        // Names that differ only in letter case. On a case-insensitive disk
        // (the Mac default; Windows servers) they are the same item, so
        // "transfer the one, delete the other" would destroy it.
        var sourceSpellings: [String: Set<String>] = [:], destinationSpellings: [String: Set<String>] = [:]
        for entry in source { sourceSpellings[fold(entry.relativePath), default: []].insert(entry.relativePath) }
        for entry in destination { destinationSpellings[fold(entry.relativePath), default: []].insert(entry.relativePath) }
        for entry in source {
            let key = fold(entry.relativePath)
            guard untouchable[key] == nil, let there = destinationSpellings[key], there != sourceSpellings[key] else { continue }
            untouchable[key] = (entry.relativePath, entry.isDirectory,
                                "the two sides spell this name with different letter case")
        }

        // Symbolic links are never followed or copied; nor is whatever has
        // the link's name on the other side replaced or removed.
        for entry in allSource + allDestination where entry.isOpaque && !isExcluded(entry) {
            let key = fold(entry.relativePath)
            guard untouchable[key] == nil else { continue }
            let hasCounterpart = sourceSpellings[key] != nil || destinationSpellings[key] != nil
            untouchable[key] = (entry.relativePath, false,
                                hasCounterpart ? "a symbolic link on one side; left alone" : nil)
        }

        let untouchableKeys = Set(untouchable.keys)
        func isUntouchable(_ path: String) -> Bool {
            var key = fold(path)
            while true {
                if untouchableKeys.contains(key) { return true }
                guard let slash = key.lastIndex(of: "/") else { return false }
                key = String(key[..<slash])
            }
        }

        // Destination folders that hold something excluded or otherwise left
        // alone can't be removed without taking that item with them.
        var protectedFolders: Set<String> = []
        for entry in allDestination where isExcluded(entry) || entry.isOpaque {
            var path = entry.relativePath
            while let slash = path.lastIndex(of: "/") {
                path = String(path[..<slash])
                protectedFolders.insert(path)
            }
        }

        var create: [SyncAction] = [], transfer: [SyncAction] = [], delete: [SyncAction] = [], skip: [SyncAction] = []
        var uncertain: [String] = []

        // One line per left-alone item — the topmost, not everything under it.
        for (key, item) in untouchable.sorted(by: { $0.value.path < $1.value.path }) {
            guard let reason = item.reason else { continue }
            let parent = key.lastIndex(of: "/").map { String(key[..<$0]) }
            if let parent, isUntouchable(parent) { continue }
            skip.append(SyncAction(relativePath: item.path, kind: .skip, isDirectory: item.isDirectory, size: nil, reason: reason))
        }

        for entry in source.sorted(by: { $0.relativePath < $1.relativePath }) {
            let path = entry.relativePath
            if isUntouchable(path) { continue }

            let existing = destinationByPath[path]
            if entry.isDirectory {
                if existing == nil {
                    create.append(SyncAction(relativePath: path, kind: .createDirectory, isDirectory: true, size: nil, reason: "new folder"))
                }
                continue
            }
            if let reason = reasonToTransfer(entry, over: existing, options: options) {
                transfer.append(SyncAction(relativePath: path, kind: .transfer, isDirectory: false, size: entry.size, reason: reason))
            }
            if let existing, isTimeUncertain(entry, existing, options: options) {
                uncertain.append(path)
            }
        }

        if options.deleteExtraneous {
            let extraneous = destination.filter { sourceByPath[$0.relativePath] == nil && !isUntouchable($0.relativePath) }
            // Deepest first, so a folder is empty by the time its turn comes.
            for entry in extraneous.sorted(by: Self.deeperFirst) {
                if entry.isDirectory, protectedFolders.contains(entry.relativePath) {
                    skip.append(SyncAction(relativePath: entry.relativePath, kind: .skip, isDirectory: true, size: nil,
                                           reason: "not in the source, but holds items that are left alone"))
                } else {
                    delete.append(SyncAction(relativePath: entry.relativePath, kind: .delete, isDirectory: entry.isDirectory,
                                             size: entry.size, reason: "not in the source"))
                }
            }
        }

        return SyncPlan(direction: direction, actions: create + transfer + delete + skip, uncertain: uncertain)
    }

    /// A same-size pair whose times can't be compared from the listing alone.
    private static func isTimeUncertain(_ source: SyncEntry, _ existing: SyncEntry, options: SyncOptions) -> Bool {
        guard !options.sizeOnly, !(source.modifiedHasSeconds && existing.modifiedHasSeconds),
              let a = source.size, let b = existing.size, a == b,
              let sourceTime = source.modified, let existingTime = existing.modified else { return false }
        return abs(sourceTime.timeIntervalSince(existingTime)) <= timeZoneReach
    }

    /// Why `source` should replace `existing`, or nil when they are in sync.
    private static func reasonToTransfer(_ source: SyncEntry, over existing: SyncEntry?, options: SyncOptions) -> String? {
        guard let existing else { return "new" }
        if let a = source.size, let b = existing.size, a != b { return "size differs" }
        if options.sizeOnly { return nil }
        guard let sourceTime = source.modified, let existingTime = existing.modified else { return nil }
        let allowed = source.modifiedHasSeconds && existing.modifiedHasSeconds ? tolerance : coarseTolerance
        return sourceTime.timeIntervalSince(existingTime) > allowed ? "newer" : nil
    }

    private static func deeperFirst(_ a: SyncEntry, _ b: SyncEntry) -> Bool {
        let depthA = a.relativePath.split(separator: "/").count, depthB = b.relativePath.split(separator: "/").count
        return depthA != depthB ? depthA > depthB : a.relativePath < b.relativePath
    }

    // MARK: - Comparing two folders

    public struct Comparison: Sendable {
        public let local: [SyncEntry]
        public let remote: [SyncEntry]
        public let plan: SyncPlan
    }

    /// Scan both folders and work out what syncing them would do. Changes
    /// nothing on either side.
    ///
    /// The source must exist; a destination that doesn't is simply empty (it
    /// is created when the plan is carried out).
    public static func compare(
        localRoot: URL, remoteRoot: String, client: RemoteClient,
        direction: SyncDirection, options: SyncOptions = SyncOptions(), limit: Int = defaultLimit
    ) async throws -> Comparison {
        let local = try scanLocal(localRoot, excludes: options.excludes, limit: limit,
                                  missingRootIsEmpty: direction == .download)
        let remote = try await scanRemote(client, root: remoteRoot, excludes: options.excludes, limit: limit,
                                          missingRootIsEmpty: direction == .upload)
        let rough = try plan(local: local, remote: remote, direction: direction, options: options)
        let refined = options.sizeOnly
            ? rough
            : await refine(rough, local: local, remote: remote, remoteRoot: remoteRoot, client: client)
        return Comparison(local: local, remote: remote, plan: refined)
    }

    // MARK: - Refining

    /// Settle the pairs the listing couldn't (`SyncPlan.uncertain`) by asking
    /// the server for each file's exact modification time.
    ///
    /// FTP `LIST` reports times to the minute and in the server's own time
    /// zone, so a file can appear hours older or newer than it is: a recent
    /// upload looks stale and is sent again on every run, or a same-size
    /// local edit hides behind a copy that only looks newer. Only same-size
    /// files changed within a time zone's reach of each other are asked
    /// about; listings with exact times (SFTP, MLSD) cost nothing here.
    public static func refine(
        _ plan: SyncPlan, local: [SyncEntry], remote: [SyncEntry], remoteRoot: String, client: RemoteClient
    ) async -> SyncPlan {
        guard !plan.uncertain.isEmpty else { return plan }
        let localByPath = Dictionary(local.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByPath = Dictionary(remote.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var transfers = Dictionary(plan.transfers.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        for path in plan.uncertain {
            // No exact time to be had (no MDTM): the listing's verdict stands.
            guard let localTime = localByPath[path]?.modified,
                  let exact = await client.remoteModifiedDate(at: joined(remoteRoot, path)) else { continue }
            let sourceTime = plan.direction == .upload ? localTime : exact
            let destinationTime = plan.direction == .upload ? exact : localTime
            if sourceTime.timeIntervalSince(destinationTime) > tolerance {
                let size = (plan.direction == .upload ? localByPath[path] : remoteByPath[path])?.size
                transfers[path] = SyncAction(relativePath: path, kind: .transfer, isDirectory: false, size: size, reason: "newer")
            } else {
                transfers[path] = nil
            }
        }

        var refined = plan
        refined.uncertain = []
        refined.actions = plan.directories + transfers.values.sorted { $0.relativePath < $1.relativePath }
            + plan.deletions + plan.skips
        return refined
    }

    /// The remote path of `relativePath` under `root`.
    public static func joined(_ root: String, _ relativePath: String) -> String {
        relativePath.split(separator: "/").reduce(root) { RemotePath.join($0, String($1)) }
    }

    // MARK: - Scanning

    // Both scanners report an excluded item but never look inside it: the
    // planner needs to know it is there (to leave it, and the folders above
    // it, alone) without paying to walk a `node_modules`. Symlinks are
    // skipped entirely, as in folder transfers — following them risks cycles
    // and escapes from the tree being synced.

    /// Everything under the local folder `root`.
    /// - Parameter missingRootIsEmpty: for a destination that will be
    ///   created. A missing *source* must stay an error: an unmounted volume
    ///   is not an empty folder.
    public static func scanLocal(
        _ root: URL, excludes: [String] = [], limit: Int = defaultLimit, missingRootIsEmpty: Bool = false
    ) throws -> [SyncEntry] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if missingRootIsEmpty { return [] }
            throw FolderSyncError.sourceMissing(root.path)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        // A folder that can't be read must stop the scan. Carrying on would
        // report it as empty, and a sync with deletion on would then remove
        // everything under it on the other side.
        var unreadable: String?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [],
            errorHandler: { url, _ in
                unreadable = unreadable ?? url.path
                return false
            }
        ) else {
            throw FolderSyncError.sourceMissing(root.path)
        }
        let patterns = builtInExcludes + excludes
        var entries: [SyncEntry] = []

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                throw FolderSyncError.unreadable(url.path)
            }
            // The enumerator's depth says how many trailing components are
            // inside the root. (Comparing against the root's own path breaks
            // when that path runs through a link, as /var and /tmp do.)
            let components = url.pathComponents.suffix(enumerator.level)
            guard !components.isEmpty, components.allSatisfy({ RemotePath.sanitizedFilename($0) != nil }) else {
                enumerator.skipDescendants()
                continue
            }
            let relative = components.joined(separator: "/")
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                entries.append(SyncEntry(relativePath: relative, isDirectory: false, isOpaque: true))
                continue
            }
            let isFolder = values.isDirectory == true
            entries.append(SyncEntry(
                relativePath: relative, isDirectory: isFolder,
                size: isFolder ? nil : values.fileSize.map(Int64.init),
                modified: isFolder ? nil : values.contentModificationDate
            ))
            if entries.count > limit { throw FolderSyncError.tooLarge(limit: limit) }
            if patterns.contains(where: { matches(exclude: $0, relativePath: relative) }) {
                enumerator.skipDescendants()
            }
        }
        if let unreadable { throw FolderSyncError.unreadable(unreadable) }
        return entries
    }

    /// Everything under the remote folder `root`.
    /// - Parameter missingRootIsEmpty: as for `scanLocal`.
    public static func scanRemote(
        _ client: RemoteClient, root: String, excludes: [String] = [],
        limit: Int = defaultLimit, missingRootIsEmpty: Bool = false
    ) async throws -> [SyncEntry] {
        let patterns = builtInExcludes + excludes
        var entries: [SyncEntry] = []
        // "/var/www/" and "/var/www" are the same folder; "/" stays "/".
        let root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        var pending: [(remote: String, relative: String)] = [(root, "")]
        var isRoot = true

        while let (directory, prefix) = pending.popLast() {
            let items: [FileItem]
            do {
                items = try await client.listDirectory(at: directory)
            } catch {
                // "Couldn't list it" only means "not there yet" if its parent
                // agrees. A permission error or timeout on a folder that does
                // exist must not pass for an empty destination.
                if isRoot, missingRootIsEmpty, await !exists(root, on: client) { return [] }
                throw error
            }
            isRoot = false
            for item in items {
                guard let name = RemotePath.sanitizedFilename(item.name) else { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                if item.isSymlink {
                    entries.append(SyncEntry(relativePath: relative, isDirectory: false, isOpaque: true))
                    if entries.count > limit { throw FolderSyncError.tooLarge(limit: limit) }
                    continue
                }
                entries.append(SyncEntry(
                    relativePath: relative, isDirectory: item.isDirectory,
                    size: item.isDirectory ? nil : item.size,
                    modified: item.isDirectory ? nil : item.modifiedDate,
                    // A time landing exactly on the minute is taken to have no
                    // seconds (LIST-only FTP servers). Occasionally that is a
                    // real :00, which only costs a slightly wider tolerance.
                    modifiedHasSeconds: item.modifiedDate.map { Int($0.timeIntervalSince1970) % 60 != 0 } ?? true
                ))
                if entries.count > limit { throw FolderSyncError.tooLarge(limit: limit) }
                let excluded = patterns.contains { matches(exclude: $0, relativePath: relative) }
                if item.isDirectory, !excluded {
                    pending.append((RemotePath.join(directory, name), relative))
                }
            }
        }
        return entries
    }

    /// Whether the remote folder `path` is listed by its parent. When the
    /// parent can't be listed either, there is nothing to say it exists.
    private static func exists(_ path: String, on client: RemoteClient) async -> Bool {
        guard path != "/" else { return true }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let siblings = try? await client.listDirectory(at: parent.isEmpty ? "/" : parent) else { return false }
        return siblings.contains { $0.name == name }
    }

    // MARK: - Excludes

    /// Whether `pattern` excludes `relativePath` — itself or any folder above
    /// it. A pattern without a slash is matched against each path component
    /// (`node_modules`, `*.log`); one with a slash against the path from the
    /// sync root (`build/cache`, `img/*.psd`). `*` and `?` are wildcards;
    /// matching is case-sensitive.
    ///
    /// rsync-style decorations are understood rather than silently matching
    /// nothing: a trailing slash (`uploads/`) and a leading `./` are dropped,
    /// and a leading slash (`/uploads`) anchors the pattern to the sync root.
    public static func matches(exclude pattern: String, relativePath: String) -> Bool {
        var pattern = Substring(pattern)
        while pattern.hasPrefix("./") { pattern = pattern.dropFirst(2) }
        var anchored = pattern.hasPrefix("/")
        while pattern.hasPrefix("/") { pattern = pattern.dropFirst() }
        while pattern.hasSuffix("/") { pattern = pattern.dropLast() }
        guard !pattern.isEmpty else { return false }
        anchored = anchored || pattern.contains("/")

        var prefix = ""
        for component in relativePath.split(separator: "/").map(String.init) {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            if SSHConfig.glob(String(pattern), matches: anchored ? prefix : component, caseSensitive: true) { return true }
        }
        return false
    }
}
