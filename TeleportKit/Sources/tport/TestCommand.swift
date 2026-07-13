import ArgumentParser
import TeleportCLICore

struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "test", abstract: "Check connectivity and authentication only.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL to test.")
    var url: String

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await withConnectedClient(client) { _ in
                if !global.quiet { print("ok") }
            }
        }
    }
}
