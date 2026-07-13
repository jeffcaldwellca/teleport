import ArgumentParser
import TeleportCLICore
import TeleportKit

struct MkdirCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mkdir", abstract: "Create a remote directory.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL of the directory to create.")
    var url: String

    @Flag(name: .shortAndLong, help: "Create intermediate parent directories as needed.")
    var parents = false

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await withConnectedClient(client) { client in
                if parents {
                    var accumulated = ""
                    for component in target.path.split(separator: "/") {
                        accumulated += "/\(component)"
                        try await createDirectoryTolerantly(client, at: accumulated)
                    }
                } else {
                    try await client.createDirectory(at: target.path)
                }
            }
        }
    }

    /// Creates `path`, tolerating "already exists" (mkdir -p is idempotent)
    /// but surfacing any other failure (permission denied, read-only fs,
    /// quota) instead of silently swallowing it. There's no typed
    /// "already exists" error to match on here, so a failed create is
    /// checked against fileExists to tell the two apart.
    private func createDirectoryTolerantly(_ client: RemoteClient, at path: String) async throws {
        do {
            try await client.createDirectory(at: path)
        } catch {
            guard await client.fileExists(at: path) else { throw error }
        }
    }
}
