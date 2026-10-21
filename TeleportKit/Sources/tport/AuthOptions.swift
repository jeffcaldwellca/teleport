import ArgumentParser
import Foundation
import TeleportCLICore
import TeleportKit

struct AuthOptions: ParsableArguments {
    @Option(name: .long, help: "Password (prefer TELEPORT_PASSWORD or --password-stdin over this — it's visible in `ps`).")
    var password: String?

    @Flag(name: .long, help: "Read the password as a single line from stdin.")
    var passwordStdin = false

    @Option(name: .long, help: "Path to an SFTP private key (ed25519, ECDSA or RSA). A passphrase is read from TELEPORT_KEY_PASSPHRASE, or asked for when run from a terminal.")
    var identity: String?

    @Option(name: .long, help: "Path to an OpenSSH client config. Defaults to ~/.ssh/config. For sftp:// URLs its Host entries supply HostName, User, Port and IdentityFile where the URL and flags don't.")
    var sshConfig: String?

    @Flag(name: .long, help: "Don't read the OpenSSH client config.")
    var noSshConfig = false

    @Flag(name: .long, help: "Don't use keys from ssh-agent. (By default they are tried when neither --identity nor a password is given.)")
    var noAgent = false

    @Option(name: .long, help: "Path to the known-hosts trust file. Defaults to ~/.teleport/known_hosts.json.")
    var knownHosts: String?

    @Flag(name: .long, help: "Trust and save an unknown SSH host key instead of failing closed.")
    var acceptNewHostkey = false

    @Option(name: .long, help: "Path to the trusted FTPS certificates file. Defaults to ~/.teleport/trusted_certs.json.")
    var trustedCerts: String?

    @Flag(name: .long, help: "Trust and save an FTPS certificate the system doesn't trust (e.g. self-signed) instead of failing closed.")
    var acceptUntrustedCert = false

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

    /// The environment variable answers the first ask (so scripts work); a
    /// retry after a wrong passphrase, or no variable at all, falls to an
    /// interactive no-echo prompt — and to giving up when there's no terminal.
    @Sendable
    private static func keyPassphrase(keyPath: String, retry: Bool) async -> String? {
        if !retry, let fromEnvironment = ProcessInfo.processInfo.environment["TELEPORT_KEY_PASSPHRASE"] {
            return fromEnvironment
        }
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        let prompt = (retry ? "Wrong passphrase. " : "") + "Passphrase for \(keyPath): "
        guard let entered = getpass(prompt) else { return nil }
        return String(cString: entered)
    }

    /// Answers a server's keyboard-interactive prompts on the terminal: the
    /// configured password already answers a lone password prompt before
    /// this is asked, so what arrives here is a verification code or a
    /// custom prompt. Without a terminal there is nobody to ask.
    @Sendable
    private static func keyboardInteractivePrompts(_ challenge: KeyboardInteractiveChallenge) async -> [String]? {
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        // The challenge's text is the server's (stripped of control
        // characters on the way in); say so before showing it.
        let standardError = FileHandle.standardError
        standardError.write(Data("The server asks, to finish logging in:\n".utf8))
        for line in [challenge.name, challenge.instruction] where !line.isEmpty {
            standardError.write(Data(("  " + line.replacingOccurrences(of: "\n", with: "\n  ") + "\n").utf8))
        }
        var answers: [String] = []
        for prompt in challenge.prompts {
            if prompt.echo {
                standardError.write(Data(prompt.text.utf8))
                guard let line = readLine(strippingNewline: true) else { return nil }
                answers.append(line)
            } else {
                guard let entered = getpass(prompt.text) else { return nil }
                answers.append(String(cString: entered))
            }
        }
        return answers
    }

    static var defaultKnownHostsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".teleport/known_hosts.json")
    }

    static var defaultTrustedCertsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".teleport/trusted_certs.json")
    }

    func makeHostKeyStore() -> SSHHostKeyStore {
        let url = knownHosts.map { URL(fileURLWithPath: $0) } ?? Self.defaultKnownHostsURL
        return SSHHostKeyStore(storeURL: url)
    }

    func makeCertificateStore() -> SSHHostKeyStore {
        let url = trustedCerts.map { URL(fileURLWithPath: $0) } ?? Self.defaultTrustedCertsURL
        return SSHHostKeyStore(storeURL: url)
    }

    func makeClient(for target: RemoteTarget) throws -> RemoteClient {
        var connection = target.makeConnection()
        if let identity { connection.sshKeyPath = identity }
        let password = try resolvePassword(for: target)
        // Like ssh: with nothing else to go on, use whatever the agent holds.
        connection.useSSHAgent = !noAgent && identity == nil && password.isEmpty

        if target.connectionProtocol == .sftp, !noSshConfig {
            // The URL's host may be an ssh config alias. The config fills in
            // only what the URL and flags left unsaid.
            let config = sshConfig.map { SSHConfig.load(from: URL(fileURLWithPath: $0)) } ?? SSHConfig.load()
            let resolved = config.resolve(target.host)
            connection.host = resolved.hostName
            if !target.userSpecified, let user = resolved.user { connection.username = user }
            if !target.portSpecified, let port = resolved.port { connection.port = port }
            // A key file means the password is never sent, so a config
            // IdentityFile must not displace a password the user supplied.
            if identity == nil, password.isEmpty, let keyFile = resolved.identityFile,
               FileManager.default.fileExists(atPath: keyFile) {
                connection.sshKeyPath = keyFile
            }
            // The URL no longer says where this goes; if it fails, the error
            // needs to (most often: an unknown host key for the real address).
            if connection.host != target.host || connection.port != target.port || connection.username != target.username {
                FailureNotes.shared.sshConfigResolution =
                    "\u{2018}\(target.host)\u{2019} was resolved through the ssh config to " +
                    "\(connection.username)@\(connection.host):\(connection.port). Pass --no-ssh-config to use the URL as written."
            }
        }

        switch target.connectionProtocol {
        case .sftp:
            return SFTPClient(
                connection: connection,
                password: password,
                hostKeyStore: makeHostKeyStore(),
                onUnknownHostKey: { [acceptNewHostkey] _, _, _ in acceptNewHostkey },
                passphraseProvider: Self.keyPassphrase,
                interactivePromptProvider: Self.keyboardInteractivePrompts
            )
        case .ftp, .ftps:
            return FTPClient(
                connection: connection,
                password: password,
                certificateStore: makeCertificateStore(),
                onUntrustedCertificate: { [acceptUntrustedCert] _ in acceptUntrustedCert },
                // tport runs one operation at a time, so transfers can use the
                // session's own connection instead of a fresh login per file.
                dedicatedToTransfers: true
            )
        }
    }
}
