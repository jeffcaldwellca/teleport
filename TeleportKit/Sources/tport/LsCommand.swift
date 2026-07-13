import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct LsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List a remote directory.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL of the directory to list.")
    var url: String

    @Flag(help: "List subdirectories recursively.")
    var recursive = false

    @Flag(help: "Emit machine-readable JSON instead of a text table.")
    var json = false

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }

            let items = recursive
                ? try await listRecursive(client: client, path: target.path)
                : try await client.listDirectory(at: target.path)

            if json {
                print(try JSONOutput.encode(items))
            } else {
                for item in items.sorted(by: { $0.path < $1.path }) {
                    let size = item.isDirectory ? "-" : "\(item.size ?? 0)"
                    print("\(item.isDirectory ? "d" : "-")\t\(size)\t\(item.path)")
                }
            }
        }
    }

    private func listRecursive(client: RemoteClient, path: String) async throws -> [FileItem] {
        var result: [FileItem] = []
        var pending = [path]
        while let dir = pending.popLast() {
            let entries = try await client.listDirectory(at: dir)
            for entry in entries {
                result.append(entry)
                if entry.isDirectory && !entry.isSymlink { pending.append(entry.path) }
            }
        }
        return result
    }
}
