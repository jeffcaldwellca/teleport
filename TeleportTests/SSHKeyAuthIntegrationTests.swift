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
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Bool] = []
    func append(_ value: Bool) { lock.withLock { _values.append(value) } }
    var values: [Bool] { lock.withLock { _values } }
}
