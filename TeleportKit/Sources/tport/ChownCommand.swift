import ArgumentParser
import TeleportCLICore
import TeleportKit

struct ChownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chown", abstract: "Change ownership of a remote path (SFTP: numeric UID/GID).")

    @Argument(help: "Owner (user name for FTP, numeric UID for SFTP).")
    var owner: String

    @Argument(help: "Group (group name for FTP, numeric GID for SFTP).")
    var group: String

    @Argument(help: "sftp://, ftp://, or ftps:// URL.")
    var url: String

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await withConnectedClient(client) { client in
                try await client.setOwnership(owner: owner, group: group, at: target.path)
            }
        }
    }
}
