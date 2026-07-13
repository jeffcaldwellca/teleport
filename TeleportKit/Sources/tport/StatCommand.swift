import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct StatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stat", abstract: "Show details for one remote path.")

    @Argument(help: "sftp://, ftp://, or ftps:// URL of the item.")
    var url: String

    @Flag(help: "Emit machine-readable JSON instead of text.")
    var json = false

    @OptionGroup var auth: AuthOptions
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        try await runTport {
            let target = try RemoteTarget.parse(url)
            let client = try auth.makeClient(for: target)
            try await client.connect()
            defer { Task { await client.disconnect() } }

            guard await client.fileExists(at: target.path) else {
                throw RemoteClientError.fileNotFound(target.path)
            }
            let modified = await client.remoteModifiedDate(at: target.path)
            let item = FileItem(name: (target.path as NSString).lastPathComponent,
                                path: target.path, isDirectory: false, modifiedDate: modified)

            if json {
                print(try JSONOutput.encode(item))
            } else if !global.quiet {
                print("path:     \(item.path)")
                print("modified: \(modified.map(String.init(describing:)) ?? "unknown")")
            }
        }
    }
}
