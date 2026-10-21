import XCTest
import NIOSSH
@testable import TeleportKit

/// What `SFTPClient` tells the user when a login is turned down. The server
/// says which methods it will still take in every rejection; a bare
/// "Authentication failed" throws that away, and sends people with a working
/// key or password hunting for a typo when the server simply won't accept
/// that kind of credential (issue #4).
final class SFTPClientLoginFailureTests: XCTestCase {

    private var server: FakeSSHServer?
    private var keyDirectory: URL?

    override func tearDown() {
        server?.stop()
        if let keyDirectory { try? FileManager.default.removeItem(at: keyDirectory) }
        super.tearDown()
    }

    // MARK: - Helpers

    private func start(accepts: NIOSSHAvailableUserAuthenticationMethods, reply: FakeSSHServer.Reply) throws -> FakeSSHServer {
        let server = try FakeSSHServer(accepts: accepts, reply: reply)
        self.server = server
        return server
    }

    private func client(to server: FakeSSHServer, user: String = "alice", password: String = "", keyPath: String = "") -> SFTPClient {
        var connection = Connection(name: "fake", host: "127.0.0.1", port: server.port,
                                    username: user, connectionProtocol: .sftp)
        connection.sshKeyPath = keyPath
        return SFTPClient(
            connection: connection,
            password: password,
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true },
            agent: nil
        )
    }

    /// A fresh, unencrypted ed25519 key file in a temporary directory.
    private func makeKeyFile(named name: String = "id_test") throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "teleport-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keyDirectory = directory
        let path = directory.appending(component: name).path
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", path]
        try keygen.run()
        keygen.waitUntilExit()
        XCTAssertEqual(keygen.terminationStatus, 0, "ssh-keygen failed")
        return path
    }

    private func rejectionMessage(connecting client: SFTPClient,
                                  file: StaticString = #filePath, line: UInt = #line) async -> String {
        do {
            try await client.connect()
            XCTFail("Expected the login to be refused", file: file, line: line)
        } catch RemoteClientError.authenticationRejected(let why) {
            return why
        } catch {
            XCTFail("Expected authenticationRejected with an explanation, got \(error)", file: file, line: line)
        }
        return ""
    }

    // MARK: - Tests

    func test_passwordOffered_serverTakesKeysOnly_saysSo() async throws {
        let server = try start(accepts: [.publicKey], reply: .reject)
        let why = await rejectionMessage(connecting: client(to: server, password: "secret"))
        XCTAssertTrue(why.localizedCaseInsensitiveContains("password"), why)
        XCTAssertTrue(why.localizedCaseInsensitiveContains("key"), why)
        XCTAssertTrue(why.contains("alice"), why)
    }

    /// A server that lists only methods SwiftNIO SSH doesn't know (in
    /// practice keyboard-interactive) reaches the client as an empty list.
    func test_passwordOffered_serverWantsOnlyUnsupportedMethods_namesKeyboardInteractive() async throws {
        let server = try start(accepts: [], reply: .reject)
        let why = await rejectionMessage(connecting: client(to: server, password: "secret"))
        XCTAssertTrue(why.localizedCaseInsensitiveContains("password"), why)
        XCTAssertTrue(why.localizedCaseInsensitiveContains("keyboard-interactive"), why)
    }

    func test_keyOffered_serverTakesPasswordsOnly_saysSo() async throws {
        let server = try start(accepts: [.password], reply: .reject)
        let key = try makeKeyFile(named: "id_server")
        let why = await rejectionMessage(connecting: client(to: server, keyPath: key))
        XCTAssertTrue(why.contains("id_server"), why)
        XCTAssertTrue(why.localizedCaseInsensitiveContains("password"), why)
        XCTAssertTrue(why.contains("alice"), why)
    }

    /// OpenSSH's `AuthenticationMethods publickey,keyboard-interactive`: the
    /// key is accepted, then a second step Teleport can't do is demanded.
    func test_keyAccepted_butSecondFactorRequired_explainsInsteadOfBlamingTheKey() async throws {
        let server = try start(accepts: [.publicKey], reply: .partialSuccess(remaining: []))
        let key = try makeKeyFile(named: "id_vps")
        let why = await rejectionMessage(connecting: client(to: server, keyPath: key))
        XCTAssertTrue(why.contains("id_vps"), why)
        XCTAssertTrue(why.localizedCaseInsensitiveContains("second factor"), why)
        XCTAssertFalse(why.localizedCaseInsensitiveContains("rejected"), why)
    }

    // A plain rejection — the server still takes that kind of credential —
    // stays "Authentication failed": the credential itself was wrong.

    func test_keyRejected_serverStillTakesKeys_isAPlainAuthenticationFailure() async throws {
        let server = try start(accepts: [.publicKey, .password], reply: .reject)
        let key = try makeKeyFile()
        do {
            try await client(to: server, keyPath: key).connect()
            XCTFail("Expected the login to be refused")
        } catch RemoteClientError.authenticationFailed {
            // expected
        }
    }

    func test_passwordRejected_serverStillTakesPasswords_isAPlainAuthenticationFailure() async throws {
        let server = try start(accepts: [.password], reply: .reject)
        do {
            try await client(to: server, password: "wrong").connect()
            XCTFail("Expected the login to be refused")
        } catch RemoteClientError.authenticationFailed {
            // expected
        }
    }
}
