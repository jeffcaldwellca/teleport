import ArgumentParser

@main
struct Tport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tport",
        abstract: "Scriptable FTP/FTPS/SFTP client — the Teleport CLI.",
        subcommands: [
            LsCommand.self,
            StatCommand.self,
            GetCommand.self,
            PutCommand.self,
            TestCommand.self,
        ]
    )
}
