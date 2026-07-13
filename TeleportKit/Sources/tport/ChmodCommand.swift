import ArgumentParser
import TeleportCLICore
import TeleportKit

struct ChmodCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chmod", abstract: "Set permissions on a remote path.")

    @Argument(help: "Octal permissions, e.g. 644 or 755.")
    var octal: String

    @Argument(help: "sftp://, ftp://, or ftps:// URL.")
    var url: String

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            guard let value = Int(octal, radix: 8), value >= 0 else {
                throw TportUsageError.invalidURL("'\(octal)' isn't a valid octal permission (e.g. 644)")
            }
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }
            try await client.setPermissions(value, at: target.path)
        }
    }
}
