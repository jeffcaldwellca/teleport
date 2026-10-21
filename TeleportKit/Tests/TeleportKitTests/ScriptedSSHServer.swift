import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Citadel

/// Citadel's SSH server with scripted authentication — including
/// keyboard-interactive challenges and two-factor "partial success" — and a
/// one-file SFTP root, so `SFTPClient.connect()` can run to completion.
final class ScriptedSSHServer {

    final class Auth: NIOSSHServerUserAuthenticationDelegate, NIOSSHServerKeyboardInteractiveDelegate, @unchecked Sendable {
        struct KeyboardInteractive {
            var challenge: NIOSSHKeyboardInteractiveChallenge
            /// The responses that pass; anything else fails.
            var expected: [String]
            var onSuccess: NIOSSHKeyboardInteractiveServerStep = .success
        }

        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods
        private let passwordReply: @Sendable (String) -> NIOSSHUserAuthenticationOutcome
        private let publicKeyReply: NIOSSHUserAuthenticationOutcome
        private let keyboardInteractive: KeyboardInteractive?

        private let lock = NSLock()
        private var _challengesIssued = 0
        private var _responsesReceived: [[String]] = []
        var challengesIssued: Int { lock.withLock { _challengesIssued } }
        var responsesReceived: [[String]] { lock.withLock { _responsesReceived } }

        init(
            accepts: NIOSSHAvailableUserAuthenticationMethods,
            password: @escaping @Sendable (String) -> NIOSSHUserAuthenticationOutcome = { _ in .failure },
            publicKey: NIOSSHUserAuthenticationOutcome = .failure,
            keyboardInteractive: KeyboardInteractive? = nil
        ) {
            self.supportedAuthenticationMethods = accepts
            self.passwordReply = password
            self.publicKeyReply = publicKey
            self.keyboardInteractive = keyboardInteractive
        }

        var keyboardInteractiveDelegate: NIOSSHServerKeyboardInteractiveDelegate? {
            keyboardInteractive == nil ? nil : self
        }

        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            switch request.request {
            case .password(let password): responsePromise.succeed(passwordReply(password.password))
            case .publicKey:              responsePromise.succeed(publicKeyReply)   // signature already verified
            default:                      responsePromise.succeed(.failure)
            }
        }

        func keyboardInteractiveBegan(username: String, submethods: String,
                                      promise: EventLoopPromise<NIOSSHKeyboardInteractiveServerStep>) {
            guard let script = keyboardInteractive else { return promise.succeed(.failure) }
            lock.withLock { _challengesIssued += 1 }
            promise.succeed(.challenge(script.challenge))
        }

        func keyboardInteractiveResponded(username: String, responses: [String],
                                          promise: EventLoopPromise<NIOSSHKeyboardInteractiveServerStep>) {
            guard let script = keyboardInteractive else { return promise.succeed(.failure) }
            lock.withLock { _responsesReceived.append(responses) }
            promise.succeed(responses == script.expected ? script.onSuccess : .failure)
        }
    }

    let port: Int
    let auth: Auth
    /// The usernames the SFTP subsystem was given for each session.
    let usernames = Recorder<String>()
    private let server: SSHServer

    init(auth: Auth) async throws {
        self.auth = auth
        let probe = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).wait()
        guard let port = probe.localAddress?.port else { throw POSIXError(.EADDRNOTAVAIL) }
        try probe.close().wait()
        self.port = port
        server = try await SSHServer.host(
            host: "127.0.0.1", port: port,
            hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
            authenticationDelegate: auth
        )
        server.enableSFTP(withDelegate: SFTPListingLimitTests.ScriptedSFTP(behaviour: .directoryEntries(1), usernames: usernames))
    }

    func stop() async {
        try? await server.close()
    }
}
