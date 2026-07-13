import ArgumentParser
import TeleportCLICore
import TeleportKit

struct RmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a remote file or (with --recursive) directory tree.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL to delete.")
    var url: String

    @Flag(help: "Delete a directory and everything under it.")
    var recursive = false

    @Option(help: "Safety cap on entries visited during a recursive delete.")
    var maxItems: Int = FolderWalk.defaultLimit

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await withConnectedClient(client) { client in
                if recursive {
                    var count = 0
                    try await deleteRecursive(client: client, path: target.path, limit: maxItems, count: &count)
                } else {
                    try await client.delete(at: target.path, isDirectory: false)
                }
            }
        }
    }

    /// Deletes children before their parent (required — a non-empty
    /// directory can't be removed), so this stays recursive rather than
    /// iterative; `count` is threaded through by reference so the safety cap
    /// is a true running total across the whole tree, not a per-call count.
    private func deleteRecursive(client: RemoteClient, path: String, limit: Int, count: inout Int) async throws {
        let entries = try await client.listDirectory(at: path)
        for entry in entries {
            count += 1
            if count > limit { throw FolderWalkError.tooLarge(limit: limit) }
            if entry.isDirectory && !entry.isSymlink {
                try await deleteRecursive(client: client, path: entry.path, limit: limit, count: &count)
            } else {
                try await client.delete(at: entry.path, isDirectory: false)
            }
        }
        try await client.delete(at: path, isDirectory: true)
    }
}
