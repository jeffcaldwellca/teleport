import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct StatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stat", abstract: "Show details for one remote path.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL of the item.")
    var url: String

    @Flag(help: "Emit machine-readable JSON instead of text.")
    var json = false

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await withConnectedClient(client) { client in
                let item = try await stat(client, path: target.path)

                if json {
                    print(try JSONOutput.encode(item))
                } else if !global.quiet {
                    print("path:     \(item.path)")
                    print("type:     \(item.isDirectory ? "directory" : "file")")
                    if !item.isDirectory { print("size:     \(item.size ?? 0)") }
                    print("modified: \(item.modifiedDate.map(String.init(describing:)) ?? "unknown")")
                }
            }
        }
    }

    /// `fileExists`/`remoteModifiedDate` alone can't say whether a path is a
    /// directory (FTP's SIZE, which fileExists relies on, is undefined for
    /// directories per RFC 3659 and most servers reject it outright — so a
    /// directory target used to look nonexistent). Listing the parent and
    /// matching by name gives real attributes uniformly across FTP and SFTP.
    private func stat(_ client: RemoteClient, path: String) async throws -> FileItem {
        if path == "/" {
            // Root has no parent to list it from; it's always a directory.
            return FileItem(name: "/", path: "/", isDirectory: true)
        }
        let parentPath = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let siblings = try await client.listDirectory(at: parentPath.isEmpty ? "/" : parentPath)
        guard let item = siblings.first(where: { $0.name == name }) else {
            throw RemoteClientError.fileNotFound(path)
        }
        return item
    }
}
