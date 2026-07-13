import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct PutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "put", abstract: "Upload a local file or (with --recursive) folder.")

    @Argument(help: "Local file or folder to upload.")
    var local: String

    @Argument(help: "Destination sftp://, ftp://, or ftps:// URL.")
    var url: String

    @Flag(help: "Upload a folder recursively.")
    var recursive = false

    @Flag(help: "Resume an interrupted upload from the remote file's current size.")
    var resume = false

    @Option(help: "Conflict handling when the destination already exists: overwrite, skip, or ifNewer.")
    var onConflict: ConflictPolicy = .skip

    @Option(help: "Safety cap on files in a recursive upload.")
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
                    try await putFolder(client: client, localURL: localURL, remoteParent: target.path)
                } else {
                    try await putFile(client: client, localURL: localURL, remotePath: target.path)
                }
            }
        }
    }

    private func putFile(client: RemoteClient, localURL: URL, remotePath: String) async throws {
        let exists = await client.fileExists(at: remotePath)
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
        let decision = decideConflict(policy: onConflict, exists: exists, localDate: localDate, remoteDate: remoteDate, direction: .put)
        guard decision == .proceed else {
            if !global.quiet { FileHandle.standardError.write(Data("skipped (exists): \(remotePath)\n".utf8)) }
            return
        }
        let printer = ProgressPrinter(label: localURL.lastPathComponent)
        try await client.upload(from: localURL, remotePath: remotePath, resume: resume) { bytes, total in
            printer.update(bytes: bytes, total: total)
        }
        printer.finish()
        if !global.quiet { print(remotePath) }
    }

    private func putFolder(client: RemoteClient, localURL: URL, remoteParent: String) async throws {
        guard let folderName = RemotePath.sanitizedFilename(localURL.lastPathComponent) else {
            throw FolderWalkError.unsafeName(localURL.lastPathComponent)
        }
        let (dirs, files) = try FolderWalk.localTree(at: localURL, limit: maxItems)
        let sep = remoteParent.hasSuffix("/") ? "" : "/"
        let root = "\(remoteParent)\(sep)\(folderName)"

        try? await client.createDirectory(at: root)
        for dir in dirs.sorted() {
            try? await client.createDirectory(at: "\(root)/\(dir)")
        }
        for (local, relative) in files {
            try await putFile(client: client, localURL: local, remotePath: "\(root)/\(relative)")
        }
    }
}
