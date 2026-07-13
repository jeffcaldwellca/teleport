import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct GetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "get", abstract: "Download a remote file or (with --recursive) folder.")

    @Argument(help: "Source sftp://, ftp://, or ftps:// URL.")
    var url: String

    @Argument(help: "Local destination file or folder.")
    var local: String

    @Flag(help: "Download a folder recursively.")
    var recursive = false

    @Flag(help: "Resume an interrupted download from the local file's current size.")
    var resume = false

    @Option(help: "Conflict handling when the destination already exists: overwrite, skip, or ifNewer.")
    var onConflict: ConflictPolicy = .skip

    @Option(help: "Safety cap on files in a recursive download.")
    var maxItems: Int = FolderWalk.defaultLimit

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let localURL = URL(fileURLWithPath: local)
            let client = try auth.makeClient(for: target)
            try await withConnectedClient(client) { client in
                if recursive {
                    try await getFolder(client: client, remotePath: target.path, into: localURL, limit: maxItems)
                } else {
                    try await getFile(client: client, remotePath: target.path, localURL: localURL)
                }
            }
        }
    }

    private func getFile(client: RemoteClient, remotePath: String, localURL: URL) async throws {
        let exists = FileManager.default.fileExists(atPath: localURL.path)
        // remoteModifiedDate is a network round trip decideConflict only
        // consults for .ifNewer -- skip it for .overwrite/.skip, and skip it
        // entirely when the destination doesn't exist (decideConflict always
        // proceeds in that case regardless of policy).
        var localDate: Date? = nil
        var remoteDate: Date? = nil
        if exists && onConflict == .ifNewer {
            localDate = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            remoteDate = await client.remoteModifiedDate(at: remotePath)
        }
        let decision = decideConflict(policy: onConflict, exists: exists, localDate: localDate, remoteDate: remoteDate, direction: .get)
        guard decision == .proceed else {
            if !global.quiet { FileHandle.standardError.write(Data("skipped (exists): \(localURL.path)\n".utf8)) }
            return
        }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let printer = ProgressPrinter(label: localURL.lastPathComponent)
        try await client.download(remotePath: remotePath, to: localURL, resume: resume) { bytes, total in
            printer.update(bytes: bytes, total: total)
        }
        printer.finish()
        if !global.quiet { print(localURL.path) }
    }

    /// Two-phase: fully walk and count the remote tree first (no local
    /// filesystem side effects), then create directories and download files
    /// only once the whole walk is known to fit within `limit`. Mirrors
    /// PutCommand.putFolder's shape -- a `tooLarge` abort must not leave
    /// orphaned local directories behind, and the item count must be a
    /// monotonically increasing running total (not the current work-queue
    /// size, which can stay small forever for a deep chain of single-child
    /// directories and never trip the cap).
    private func getFolder(client: RemoteClient, remotePath: String, into localParent: URL, limit: Int) async throws {
        let folderName = (remotePath as NSString).lastPathComponent
        guard let safeName = RemotePath.sanitizedFilename(folderName) else {
            throw FolderWalkError.unsafeName(folderName)
        }
        let root = localParent.appending(component: safeName)

        var pendingDirs: [(remote: String, local: URL)] = [(remotePath, root)]
        var dirsToCreate: [URL] = []
        var files: [(remote: String, local: URL)] = []
        var totalSeen = 0

        while let (remoteDir, localDir) = pendingDirs.popLast() {
            dirsToCreate.append(localDir)
            for item in try await client.listDirectory(at: remoteDir) {
                guard let name = RemotePath.sanitizedFilename(item.name) else { continue }
                let childLocal = localDir.appending(component: name)
                guard RemotePath.isContained(childLocal, in: localDir) else { continue }
                if item.isSymlink { continue }
                totalSeen += 1
                if totalSeen > limit { throw FolderWalkError.tooLarge(limit: limit) }
                if item.isDirectory {
                    pendingDirs.append((item.path, childLocal))
                } else {
                    files.append((item.path, childLocal))
                }
            }
        }

        for dir in dirsToCreate {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for (remote, local) in files {
            try await getFile(client: client, remotePath: remote, localURL: local)
        }
    }
}
