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

    public init(relativePath: String, isDirectory: Bool, size: Int64? = nil,
                modified: Date? = nil, modifiedHasSeconds: Bool = true) {
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.modifiedHasSeconds = modifiedHasSeconds
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

    public var errorDescription: String? {
        switch self {
        case .emptySourceWithDeletion:
            return "The source folder is empty, so syncing with deletion on would remove everything at the " +
                   "destination. If that is really what you want, allow an empty source explicitly."
        case .sourceMissing(let path):
            return "The folder \(path) doesn't exist."
        case .tooLarge(let limit):
            return "The folder contains more than \(limit) items. Sync it in smaller pieces."
        }
    }
}

public enum FolderSync {

    /// Most entries a side may have.
    public static let defaultLimit = 10_000

    /// Always ignored, on both sides.
    public static let builtInExcludes = [".DS_Store"]

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

        let allSource = direction == .upload ? local : remote
        let allDestination = direction == .upload ? remote : local
        let source = allSource.filter { !isExcluded($0) }
        let destination = allDestination.filter { !isExcluded($0) }

        if options.deleteExtraneous, source.isEmpty, !options.allowEmptySource {
            throw FolderSyncError.emptySourceWithDeletion
        }

        let sourceByPath = Dictionary(source.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let destinationByPath = Dictionary(destination.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        // A file on one side where the other has a folder. Neither is
        // replaced, and nothing beneath that path is touched on either side.
        let conflicts = Set(source.compactMap { entry -> String? in
            guard let other = destinationByPath[entry.relativePath], other.isDirectory != entry.isDirectory else { return nil }
            return entry.relativePath
        })
        func isUnderConflict(_ path: String) -> Bool {
            conflicts.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        // Destination folders that hold something excluded can't be removed
        // without taking the excluded item with them.
        var protectedFolders: Set<String> = []
        for entry in allDestination where isExcluded(entry) {
            var path = entry.relativePath
            while let slash = path.lastIndex(of: "/") {
                path = String(path[..<slash])
                protectedFolders.insert(path)
            }
        }

        var create: [SyncAction] = [], transfer: [SyncAction] = [], delete: [SyncAction] = [], skip: [SyncAction] = []

        for entry in source.sorted(by: { $0.relativePath < $1.relativePath }) {
            let path = entry.relativePath
            if conflicts.contains(path) {
                let (here, there) = direction == .upload ? ("locally", "on the server") : ("on the server", "locally")
                skip.append(SyncAction(
                    relativePath: path, kind: .skip, isDirectory: entry.isDirectory, size: nil,
                    reason: entry.isDirectory ? "a folder \(here) but a file \(there)" : "a file \(here) but a folder \(there)"
                ))
                continue
            }
            if isUnderConflict(path) { continue }

            let existing = destinationByPath[path]
            if entry.isDirectory {
                if existing == nil {
                    create.append(SyncAction(relativePath: path, kind: .createDirectory, isDirectory: true, size: nil, reason: "new folder"))
                }
            } else if let reason = reasonToTransfer(entry, over: existing, options: options) {
                transfer.append(SyncAction(relativePath: path, kind: .transfer, isDirectory: false, size: entry.size, reason: reason))
            }
        }

        if options.deleteExtraneous {
            let extraneous = destination.filter { sourceByPath[$0.relativePath] == nil && !isUnderConflict($0.relativePath) }
            // Deepest first, so a folder is empty by the time its turn comes.
            for entry in extraneous.sorted(by: Self.deeperFirst) {
                if entry.isDirectory, protectedFolders.contains(entry.relativePath) {
                    skip.append(SyncAction(relativePath: entry.relativePath, kind: .skip, isDirectory: true, size: nil,
                                           reason: "not in the source, but holds excluded items"))
                } else {
                    delete.append(SyncAction(relativePath: entry.relativePath, kind: .delete, isDirectory: entry.isDirectory,
                                             size: entry.size, reason: "not in the source"))
                }
            }
        }

        return SyncPlan(direction: direction, actions: create + transfer + delete + skip)
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
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            throw FolderSyncError.sourceMissing(root.path)
        }
        let patterns = builtInExcludes + excludes
        let baseCount = root.standardizedFileURL.pathComponents.count
        var entries: [SyncEntry] = []

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let components = url.standardizedFileURL.pathComponents.dropFirst(baseCount)
            guard !components.isEmpty, components.allSatisfy({ RemotePath.sanitizedFilename($0) != nil }) else {
                enumerator.skipDescendants()
                continue
            }
            let relative = components.joined(separator: "/")
            let isFolder = values?.isDirectory == true
            entries.append(SyncEntry(
                relativePath: relative, isDirectory: isFolder,
                size: isFolder ? nil : (values?.fileSize).map(Int64.init),
                modified: isFolder ? nil : values?.contentModificationDate
            ))
            if entries.count > limit { throw FolderSyncError.tooLarge(limit: limit) }
            if patterns.contains(where: { matches(exclude: $0, relativePath: relative) }) {
                enumerator.skipDescendants()
            }
        }
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
                if isRoot, missingRootIsEmpty { return [] }
                throw error
            }
            isRoot = false
            for item in items where !item.isSymlink {
                guard let name = RemotePath.sanitizedFilename(item.name) else { continue }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
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

    // MARK: - Excludes

    /// Whether `pattern` excludes `relativePath` — itself or any folder above
    /// it. A pattern without a slash is matched against each path component
    /// (`node_modules`, `*.log`); one with a slash against the path from the
    /// sync root (`build/cache`, `img/*.psd`). `*` and `?` are wildcards;
    /// matching is case-sensitive.
    public static func matches(exclude pattern: String, relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        let anchored = pattern.contains("/")
        var prefix = ""
        for component in components {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            if SSHConfig.glob(pattern, matches: anchored ? prefix : component, caseSensitive: true) { return true }
        }
        return false
    }
}
