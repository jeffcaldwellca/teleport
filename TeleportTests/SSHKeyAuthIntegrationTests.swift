import XCTest
import TeleportKit

/// Key-based SFTP logins against the docker SFTP server. Skipped unless
/// `TELEPORT_IT=1` and `scripts/start-test-servers.sh` has generated the test
/// keys (it also authorises them on the server).
final class SSHKeyAuthIntegrationTests: XCTestCase {

    private static let keys = URL(fileURLWithPath: "/tmp/teleport-it-keys")

    private func requireServers() throws {
        guard ProcessInfo.processInfo.environment["TELEPORT_IT"] == "1" else {
            throw XCTSkip("Set TELEPORT_IT=1 with the local docker test servers running")
        }
        guard FileManager.default.fileExists(atPath: Self.keys.appending(component: "ed25519").path) else {
            throw XCTSkip("Run scripts/start-test-servers.sh to generate the test keys")
        }
    }

    private func connection(key: String?) -> Connection {
        var connection = Connection(name: "it-keys", host: "127.0.0.1", port: 2222,
                                    username: "testuser", connectionProtocol: .sftp)
        if let key { connection.sshKeyPath = Self.keys.appending(component: key).path }
        return connection
    }

    private func client(
        key: String?, password: String = "",
        passphrase: @escaping @Sendable (String, Bool) async -> String? = { _, _ in nil }
    ) -> SFTPClient {
        SFTPClient(
            connection: connection(key: key),
            password: password,
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true },
            passphraseProvider: passphrase
        )
    }

    private func assertLogsIn(_ client: SFTPClient, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await client.connect()
        _ = try await client.listDirectory(at: "/upload")
        await client.disconnect()
    }

    // MARK: - Key files

    func test_keyFile_ed25519_logsIn() async throws {
        try requireServers()
        try await assertLogsIn(client(key: "ed25519"))
    }

    func test_keyFile_ecdsa_allThreeCurves_logIn() async throws {
        try requireServers()
        for key in ["ecdsa256", "ecdsa384", "ecdsa521"] {
            try await assertLogsIn(client(key: key))
        }
    }

    func test_keyFile_rsa_logsIn() async throws {
        try requireServers()
        try await assertLogsIn(client(key: "rsa"))
    }

    func test_encryptedKey_asksForPassphrase_andRetriesAfterAWrongOne() async throws {
        try requireServers()
        let asks = Recorder()
        let client = client(key: "ed25519_enc") { _, retry in
            asks.append(retry)
            return retry ? "test-passphrase" : "not the passphrase"
        }
        try await assertLogsIn(client)
        XCTAssertEqual(asks.values, [false, true])
    }

    func test_encryptedKey_wrongThreeTimes_givesUp() async throws {
        try requireServers()
        let asks = Recorder()
        let client = client(key: "ed25519_enc") { _, retry in
            asks.append(retry)
            return "still wrong"
        }
        do {
            try await client.connect()
            XCTFail("Should not connect without the right passphrase")
        } catch RemoteClientError.authenticationRejected {
            // expected
        }
        XCTAssertEqual(asks.values.count, 3)
    }

    func test_encryptedKey_providerDeclines_failsWithoutTryingThePassword() async throws {
        try requireServers()
        // The password is correct: connecting would succeed if it were sent.
        let client = client(key: "ed25519_enc", password: "testpass") { _, _ in nil }
        do {
            try await client.connect()
            XCTFail("Declining the passphrase must not fall back to the password")
        } catch RemoteClientError.authenticationRejected {
            // expected
        }
    }

    func test_keyConfigured_passwordIsNeverOffered() async throws {
        try requireServers()
        let client = client(key: "unauthorised", password: "testpass")
        do {
            try await client.connect()
            XCTFail("A rejected key must not fall back to the password")
        } catch RemoteClientError.authenticationFailed {
            // expected
        }
    }

    /// RSA keys can only sign with SHA-1 here, which current OpenSSH servers
    /// refuse. When an RSA key is turned down, say so — a bare
    /// "authentication failed" sends people hunting for a wrong key.
    func test_rsaKeyRejected_explainsTheSHA1Limitation() async throws {
        try requireServers()
        let dir = FileManager.default.temporaryDirectory.appending(component: "teleport-rsa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let keyPath = dir.appending(component: "stranger_rsa").path
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "rsa", "-b", "2048", "-N", "", "-f", keyPath]
        try keygen.run()
        keygen.waitUntilExit()

        var connection = connection(key: nil)
        connection.sshKeyPath = keyPath
        let client = SFTPClient(connection: connection, password: "",
                                hostKeyStore: SSHHostKeyStore(storeURL: nil),
                                onUnknownHostKey: { _, _, _ in true })
        do {
            try await client.connect()
            XCTFail("A key the server doesn't know must not log in")
        } catch RemoteClientError.authenticationRejected(let message) {
            XCTAssertTrue(message.contains("RSA") && message.contains("SHA-1"), message)
        }
    }

    // MARK: - ssh-agent

    /// A real `ssh-agent` on a private socket, holding the named test keys.
    /// - Parameter requiringConfirmation: add the keys with `ssh-add -c`. The
    ///   agent then has to ask before each signature, and with no way to ask
    ///   (no askpass program) it refuses — a stand-in for the user declining.
    private func startAgent(holding keys: [String], requiringConfirmation: Bool = false) throws -> SSHAgent {
        let socket = "/tmp/tp-it-agent-\(UUID().uuidString.prefix(8)).sock"
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.environment = ["PATH": "/usr/bin:/bin"]   // no SSH_ASKPASS, no DISPLAY
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        addTeardownBlock {
            agent.terminate()
            try? FileManager.default.removeItem(atPath: socket)
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for key in keys {
            let add = Process()
            add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            add.arguments = (requiringConfirmation ? ["-c"] : []) + [Self.keys.appending(component: key).path]
            add.environment = ["SSH_AUTH_SOCK": socket]
            add.standardOutput = FileHandle.nullDevice
            add.standardError = FileHandle.nullDevice
            try add.run()
            add.waitUntilExit()
            XCTAssertEqual(add.terminationStatus, 0, "ssh-add \(key) failed")
        }
        return SSHAgent(socketPath: socket)
    }

    private func agentClient(_ agent: SSHAgent, key: String? = nil, password: String = "") -> SFTPClient {
        var connection = connection(key: key)
        connection.useSSHAgent = true
        return SFTPClient(
            connection: connection, password: password,
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true },
            agent: agent
        )
    }

    func test_agentKey_ed25519_logsIn() async throws {
        try requireServers()
        try await assertLogsIn(agentClient(try startAgent(holding: ["ed25519"])))
    }

    func test_agentKey_ecdsa_allThreeCurves_logIn() async throws {
        try requireServers()
        for key in ["ecdsa256", "ecdsa384", "ecdsa521"] {
            try await assertLogsIn(agentClient(try startAgent(holding: [key])))
        }
    }

    func test_agentKey_rsa_logsIn_onAServerThatStillAcceptsSHA1() async throws {
        try requireServers()
        try await assertLogsIn(agentClient(try startAgent(holding: ["rsa"])))
    }

    /// The right key isn't first in the agent: earlier ones are refused and
    /// the sequence moves on.
    func test_agentTriesEachKeyUntilOneIsAccepted() async throws {
        try requireServers()
        try await assertLogsIn(agentClient(try startAgent(holding: ["unauthorised", "ecdsa256"])))
    }

    func test_agentWithNoAcceptedKey_fallsBackToThePassword() async throws {
        try requireServers()
        try await assertLogsIn(agentClient(try startAgent(holding: ["unauthorised"]), password: "testpass"))
    }

    func test_agentEnabledButItsSocketIsGone_stillLogsInWithThePassword() async throws {
        try requireServers()
        try await assertLogsIn(agentClient(SSHAgent(socketPath: "/tmp/tp-it-agent-gone.sock"), password: "testpass"))
    }

    /// With a working agent key, an encrypted key file that is also
    /// configured must not be unlocked — no passphrase prompt for a key that
    /// is never needed.
    func test_agentKeyAccepted_theKeyFilesPassphraseIsNeverAskedFor() async throws {
        try requireServers()
        var connection = connection(key: "ed25519_enc")
        connection.useSSHAgent = true
        let asked = Recorder()
        let client = SFTPClient(
            connection: connection, password: "",
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true },
            passphraseProvider: { _, retry in asked.append(retry); return nil },
            agent: try startAgent(holding: ["ecdsa256"])
        )
        try await assertLogsIn(client)
        XCTAssertTrue(asked.values.isEmpty)
    }

    /// The agent lists a key but won't sign with it (the user said no, the
    /// hardware token is unplugged, …). That key is skipped like any other
    /// that didn't work; it must not end the connection attempt.
    func test_agentKeyThatWillNotSign_isSkipped_andThePasswordStillWorks() async throws {
        try requireServers()
        let agent = try startAgent(holding: ["ed25519"], requiringConfirmation: true)
        try await assertLogsIn(agentClient(agent, password: "testpass"))
    }

    /// Every rejected credential costs a connection. Those must be closed,
    /// not left waiting out the server's login timeout: sshd only tolerates
    /// about ten unauthenticated connections before it starts refusing more.
    func test_manyRejectedCredentials_doNotUseUpTheServersUnauthenticatedSlots() async throws {
        try requireServers()
        let agent = try startAgent(holding: ["unauthorised"])
        for attempt in 1...24 {
            do {
                try await assertLogsIn(agentClient(agent, password: "testpass"))
            } catch {
                return XCTFail("Attempt \(attempt) failed: \(error)")
            }
        }
    }

    func test_agentOff_itsKeysAreNotOffered() async throws {
        try requireServers()
        let agent = try startAgent(holding: ["ed25519"])
        // Agent holds a valid key, but the connection hasn't opted in.
        let client = SFTPClient(
            connection: connection(key: nil), password: "wrong-password",
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true },
            agent: agent
        )
        do {
            try await client.connect()
            XCTFail("Agent keys must not be used unless the connection enables the agent")
        } catch RemoteClientError.authenticationFailed {
            // expected
        }
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    func append(_ value: Bool) { lock.withLock { _values.append(value) } }
    var values: [Bool] { lock.withLock { _values } }
}
