import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct AuthOptions: ParsableArguments {
    @Option(name: .long, help: "Password (prefer TELEPORT_PASSWORD or --password-stdin over this — it's visible in `ps`).")
    var password: String?

    @Flag(name: .long, help: "Read the password as a single line from stdin.")
    var passwordStdin = false

    @Option(name: .long, help: "Path to an SFTP private key (unencrypted OpenSSH ed25519 or RSA).")
    var identity: String?

    @Option(name: .long, help: "Path to the known-hosts trust file. Defaults to ~/.teleport/known_hosts.json.")
    var knownHosts: String?

    @Flag(name: .long, help: "Trust and save an unknown SSH host key instead of failing closed.")
    var acceptNewHostkey = false

    /// Precedence: --password-stdin > --password > TELEPORT_PASSWORD >
    /// password embedded in the URL (user:password@host) > empty (anonymous
    /// FTP, or SFTP key auth, which ignores the password when a key is set).
    func resolvePassword(for target: RemoteTarget) throws -> String {
        if passwordStdin {
            guard let line = readLine(strippingNewline: true) else {
                throw TportUsageError.missingCredentials("--password-stdin was set but stdin produced no line")
            }
            return line
        }
        if let password { return password }
        if let env = ProcessInfo.processInfo.environment["TELEPORT_PASSWORD"] { return env }
        if let urlPassword = target.password { return urlPassword }
        return ""
    }

    private static var defaultKnownHostsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".teleport/known_hosts.json")
    }

    func makeHostKeyStore() -> SSHHostKeyStore {
        let url = knownHosts.map { URL(fileURLWithPath: $0) } ?? Self.defaultKnownHostsURL
        return SSHHostKeyStore(storeURL: url)
    }

    func makeClient(for target: RemoteTarget) throws -> RemoteClient {
        var connection = target.makeConnection()
        if let identity { connection.sshKeyPath = identity }
        let password = try resolvePassword(for: target)

        switch target.connectionProtocol {
        case .sftp:
            return SFTPClient(
                connection: connection,
                password: password,
                hostKeyStore: makeHostKeyStore(),
                onUnknownHostKey: { [acceptNewHostkey] _, _, _ in acceptNewHostkey }
            )
        case .ftp, .ftps:
            return FTPClient(connection: connection, password: password)
        }
    }
}
