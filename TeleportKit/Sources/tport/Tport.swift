import ArgumentParser
import TeleportCLICore

@main
struct Tport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tport",
        abstract: "Scriptable FTP/FTPS/SFTP client — the Teleport CLI.",
        version: TportVersion.current,
        subcommands: [
            LsCommand.self,
            StatCommand.self,
            GetCommand.self,
            PutCommand.self,
            SyncCommand.self,
            MkdirCommand.self,
            RmCommand.self,
            MvCommand.self,
            ChmodCommand.self,
            ChownCommand.self,
            TestCommand.self,
            TrustCommand.self,
        ]
    )
}
