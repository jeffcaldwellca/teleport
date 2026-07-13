import ArgumentParser
import TeleportCLICore
import TeleportKit

struct MvCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mv", abstract: "Rename or move a remote file, within a single connection.")

    @Argument(help: "Source sftp://, ftp://, or ftps:// URL.")
    var source: String

    @Argument(help: "Destination URL — must be the same scheme/host/port as source.")
    var destination: String

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let from = try RemoteTarget.parse(source)
            let to = try RemoteTarget.parse(destination)
            guard from.host == to.host, from.port == to.port, from.connectionProtocol == to.connectionProtocol else {
                throw TportUsageError.missingCredentials("mv requires source and destination on the same host:port")
            }
            let client = try auth.makeClient(for: from)
            try await withConnectedClient(client) { client in
                try await client.rename(from: from.path, to: to.path)
            }
        }
    }
}
