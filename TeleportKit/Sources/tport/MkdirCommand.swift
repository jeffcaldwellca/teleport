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
            try await client.connect()
            defer { Task { await client.disconnect() } }

            if parents {
                var accumulated = ""
                for component in target.path.split(separator: "/") {
                    accumulated += "/\(component)"
                    try? await client.createDirectory(at: accumulated)
                }
            } else {
                try await client.createDirectory(at: target.path)
            }
        }
    }
}
