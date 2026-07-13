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

    @Option(help: "Safety cap on entries visited during a recursive listing.")
    var maxItems: Int = FolderWalk.defaultLimit

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await withConnectedClient(client) { client in
                let items = recursive
                    ? try await listRecursive(client: client, path: target.path, limit: maxItems)
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
    }

    private func listRecursive(client: RemoteClient, path: String, limit: Int) async throws -> [FileItem] {
        var result: [FileItem] = []
        var pending = [path]
        var totalSeen = 0
        while let dir = pending.popLast() {
            let entries = try await client.listDirectory(at: dir)
            for entry in entries {
                totalSeen += 1
                if totalSeen > limit { throw FolderWalkError.tooLarge(limit: limit) }
                result.append(entry)
                if entry.isDirectory && !entry.isSymlink { pending.append(entry.path) }
            }
        }
        return result
    }
}
