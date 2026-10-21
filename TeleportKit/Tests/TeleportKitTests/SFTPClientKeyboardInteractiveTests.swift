import XCTest
import NIOSSH
@testable import TeleportKit

/// Logging in to servers that use keyboard-interactive (RFC 4256): the usual
/// way a VPS takes passwords, and the second step of most two-factor setups
/// (issue #4).
final class SFTPClientKeyboardInteractiveTests: XCTestCase {

    private var server: ScriptedSSHServer?
    private var keyDirectory: URL?

    override func tearDown() async throws {
        await server?.stop()
        if let keyDirectory { try? FileManager.default.removeItem(at: keyDirectory) }
    }

    private func start(_ auth: ScriptedSSHServer.Auth) async throws -> ScriptedSSHServer {
        let server = try await ScriptedSSHServer(auth: auth)
        self.server = server
        return server
    }

    private func client(
        to server: ScriptedSSHServer, password: String = "", keyPath: String = "",
        prompts: @escaping @Sendable (KeyboardInteractiveChallenge) async -> [String]? = { _ in
            XCTFail("No prompt was expected"); return nil
        }
    ) -> SFTPClient {
        var connection = Connection(name: "scripted", host: "127.0.0.1", port: server.port,
                                    username: "alice", connectionProtocol: .sftp)
        connection.sshKeyPath = keyPath
        return SFTPClient(
            connection: connection,
            password: password,
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true },
            interactivePromptProvider: prompts,
            agent: nil
        )
    }

    private func makeKeyFile() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "teleport-kbd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keyDirectory = directory
        let path = directory.appending(component: "id_test").path
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", path]
        try keygen.run()
        keygen.waitUntilExit()
        XCTAssertEqual(keygen.terminationStatus, 0, "ssh-keygen failed")
        return path
    }

    private static let passwordPrompt = NIOSSHKeyboardInteractiveChallenge(
        name: "", instruction: "", prompts: [.init(text: "Password: ", echo: false)]
    )
    private static let codePrompt = NIOSSHKeyboardInteractiveChallenge(
        name: "Two-step verification", instruction: "Open your authenticator app",
        prompts: [.init(text: "Verification code: ", echo: false)]
    )

    /// `PasswordAuthentication no`, `KbdInteractiveAuthentication yes`: the
    /// configured password answers the server's single prompt, no questions asked.
    func test_passwordTakenOnlyThroughKeyboardInteractive_logsInWithoutAPrompt() async throws {
        let server = try await start(.init(
            accepts: [.publicKey, .keyboardInteractive],
            keyboardInteractive: .init(challenge: Self.passwordPrompt, expected: ["secret"])
        ))
        let client = client(to: server, password: "secret")
        try await client.connect()
        _ = try await client.listDirectory(at: "/")
        await client.disconnect()
        XCTAssertEqual(server.auth.responsesReceived, [["secret"]])
    }

    /// The session a keyboard-interactive login opens must know who logged
    /// in, like one opened by a password: the SFTP side acts on behalf of
    /// the user.
    func test_keyboardInteractiveLogin_tellsTheSessionWhoLoggedIn() async throws {
        let server = try await start(.init(
            accepts: [.keyboardInteractive],
            keyboardInteractive: .init(challenge: Self.passwordPrompt, expected: ["secret"])
        ))
        let client = client(to: server, password: "secret")
        try await client.connect()
        _ = try await client.listDirectory(at: "/")
        await client.disconnect()
        XCTAssertEqual(server.usernames.values.first, "alice")
    }

    func test_wrongPasswordThroughKeyboardInteractive_isAPlainAuthenticationFailure() async throws {
        let server = try await start(.init(
            accepts: [.publicKey, .keyboardInteractive],
            keyboardInteractive: .init(challenge: Self.passwordPrompt, expected: ["secret"])
        ))
        do {
            try await client(to: server, password: "nope").connect()
            XCTFail("Expected the login to be refused")
        } catch RemoteClientError.authenticationFailed {
            // expected: the credential itself was wrong
        }
        XCTAssertEqual(server.auth.responsesReceived, [["nope"]], "the password is tried once, never retried")
    }

    /// `AuthenticationMethods publickey,keyboard-interactive`: the key is
    /// accepted, then the user is asked for the code, on the same connection.
    func test_keyThenVerificationCode_asksTheUserAndLogsIn() async throws {
        let server = try await start(.init(
            accepts: [.publicKey, .keyboardInteractive],
            publicKey: .partialSuccess(remainingMethods: [.keyboardInteractive]),
            keyboardInteractive: .init(challenge: Self.codePrompt, expected: ["424242"])
        ))
        let seen = Recorder<KeyboardInteractiveChallenge>()
        let client = client(to: server, keyPath: try makeKeyFile()) { challenge in
            seen.append(challenge)
            return ["424242"]
        }
        try await client.connect()
        _ = try await client.listDirectory(at: "/")
        await client.disconnect()
        XCTAssertEqual(seen.values.map(\.name), ["Two-step verification"])
        XCTAssertEqual(seen.values.first?.prompts.map(\.text), ["Verification code: "])
        XCTAssertEqual(seen.values.first?.prompts.map(\.echo), [false])
    }

    /// `AuthenticationMethods publickey,password`: the configured password is
    /// the second step — the one case a key and a password are both sent.
    func test_keyThenPassword_usesTheConfiguredPasswordAsTheSecondStep() async throws {
        let server = try await start(.init(
            accepts: [.publicKey, .password],
            password: { $0 == "secret" ? .success : .failure },
            publicKey: .partialSuccess(remainingMethods: [.password])
        ))
        let client = client(to: server, password: "secret", keyPath: try makeKeyFile())
        try await client.connect()
        await client.disconnect()
    }

    /// A key that is simply rejected must not be followed by the password.
    func test_keyRejectedOutright_passwordIsStillNeverSent() async throws {
        let server = try await start(.init(
            accepts: [.publicKey, .password],
            password: { _ in XCTFail("The password must not be sent"); return .success }
        ))
        do {
            try await client(to: server, password: "secret", keyPath: try makeKeyFile()).connect()
            XCTFail("Expected the login to be refused")
        } catch RemoteClientError.authenticationFailed {
            // expected
        }
    }

    func test_promptDismissed_saysWhatTheServerAsked() async throws {
        let server = try await start(.init(
            accepts: [.publicKey, .keyboardInteractive],
            publicKey: .partialSuccess(remainingMethods: [.keyboardInteractive]),
            keyboardInteractive: .init(challenge: Self.codePrompt, expected: ["424242"])
        ))
        do {
            try await client(to: server, keyPath: try makeKeyFile()) { _ in nil }.connect()
            XCTFail("Expected the login to be refused")
        } catch RemoteClientError.authenticationRejected(let why) {
            XCTAssertTrue(why.contains("Verification code"), why)
        }
    }
}

/// Thread-safe list for values recorded from `@Sendable` closures.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []
    func append(_ value: Value) { lock.withLock { _values.append(value) } }
    var values: [Value] { lock.withLock { _values } }
}
