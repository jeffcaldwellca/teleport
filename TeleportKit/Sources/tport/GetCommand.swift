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
            try await client.connect()
            defer { Task { await client.disconnect() } }

            if recursive {
                try await getFolder(client: client, remotePath: target.path, into: localURL, limit: maxItems)
            } else {
                try await getFile(client: client, remotePath: target.path, localURL: localURL)
            }
        }
    }

    private func getFile(client: RemoteClient, remotePath: String, localURL: URL) async throws {
        let exists = FileManager.default.fileExists(atPath: localURL.path)
        let localDate = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let remoteDate = await client.remoteModifiedDate(at: remotePath)
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

    private func getFolder(client: RemoteClient, remotePath: String, into localParent: URL, limit: Int) async throws {
        let folderName = (remotePath as NSString).lastPathComponent
        guard let safeName = RemotePath.sanitizedFilename(folderName) else {
            throw FolderWalkError.unsafeName(folderName)
        }
        var pendingDirs: [(remote: String, local: URL)] = [(remotePath, localParent.appending(component: safeName))]
        var files: [(remote: String, local: URL)] = []

        while let (remoteDir, localDir) = pendingDirs.popLast() {
            try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            for item in try await client.listDirectory(at: remoteDir) {
                guard let name = RemotePath.sanitizedFilename(item.name) else { continue }
                let childLocal = localDir.appending(component: name)
                guard RemotePath.isContained(childLocal, in: localDir) else { continue }
                if item.isSymlink { continue }
                if item.isDirectory {
                    pendingDirs.append((item.path, childLocal))
                } else {
                    files.append((item.path, childLocal))
                }
                if files.count + pendingDirs.count > limit {
                    throw FolderWalkError.tooLarge(limit: limit)
                }
            }
        }
        for (remote, local) in files {
            try await getFile(client: client, remotePath: remote, localURL: local)
        }
    }
}
