import ArgumentParser
import TeleportCLICore
import TeleportKit

struct RmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a remote file or (with --recursive) directory tree.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL to delete.")
    var url: String

    @Flag(help: "Delete a directory and everything under it.")
    var recursive = false

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }

            if recursive {
                try await deleteRecursive(client: client, path: target.path)
            } else {
                try await client.delete(at: target.path, isDirectory: false)
            }
        }
    }

    private func deleteRecursive(client: RemoteClient, path: String) async throws {
        let entries = try? await client.listDirectory(at: path)
        if let entries {
            for entry in entries {
                if entry.isDirectory && !entry.isSymlink {
                    try await deleteRecursive(client: client, path: entry.path)
                } else {
                    try await client.delete(at: entry.path, isDirectory: false)
                }
            }
        }
        try await client.delete(at: path, isDirectory: true)
    }
}
