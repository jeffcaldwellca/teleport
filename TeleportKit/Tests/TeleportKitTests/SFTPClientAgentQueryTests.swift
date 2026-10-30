import XCTest
import Darwin
import CryptoKit
@testable import TeleportKit

/// Agent keys against a real OpenSSH server, run as the current user on a
/// spare port (skipped where `/usr/sbin/sshd` can't be started).
///
/// Signing with an agent key can mean a Touch ID or confirmation prompt
/// (1Password, Secretive, `ssh-add -c`), so a key the server won't take must
/// never be signed with: each is first offered without a signature, and only
/// one the server answers with PK_OK is used to sign.
final class SFTPClientAgentQueryTests: XCTestCase {

    private var sshd: Process?
    private var agent: FakeSSHAgent?
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(component: "tp-sshd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sshd?.terminate()
        sshd?.waitUntilExit()
        agent?.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Key {
        let signing = Curve25519.Signing.PrivateKey()
        var blob: Data { FakeSSHAgent.keyBlob("ssh-ed25519", body: Array(signing.publicKey.rawRepresentation)) }
        var authorizedKeysLine: String { "ssh-ed25519 \(blob.base64EncodedString())" }
        func signatureBlob(for data: Data) -> Data? {
            guard let signature = try? signing.signature(for: data) else { return nil }
            return FakeSSHAgent.keyBlob("ssh-ed25519", body: Array(signature))
        }
    }

    private func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw POSIXError(.EADDRNOTAVAIL) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// Starts sshd accepting exactly `authorized` for the current user.
    private func startSSHD(authorizing authorized: [Key]) throws -> Int {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") else { throw XCTSkip("no sshd") }
        let hostKey = directory.appending(component: "hostkey").path
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", hostKey]
        try keygen.run()
        keygen.waitUntilExit()

        let authorizedKeys = directory.appending(component: "authorized_keys")
        try (authorized.map(\.authorizedKeysLine).joined(separator: "\n") + "\n").write(to: authorizedKeys, atomically: true, encoding: .utf8)

        let port = try freePort()
        let config = directory.appending(component: "sshd_config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        AuthorizedKeysFile \(authorizedKeys.path)
        PidFile none
        UsePAM no
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        Subsystem sftp internal-sftp
        LogLevel VERBOSE
        """.write(to: config, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-f", config.path, "-D", "-e"]
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        sshd = process

        // Wait for it to listen.
        for _ in 0..<50 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = UInt16(port).bigEndian
            let connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
            close(fd)
            if connected { return port }
            guard process.isRunning else { throw XCTSkip("sshd wouldn't start here") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw XCTSkip("sshd didn't start listening")
    }

    func test_onlyTheAgentKeyTheServerAccepts_isSignedWith() async throws {
        let rejected = Key(), accepted = Key()
        let port = try startSSHD(authorizing: [accepted])

        let fake = try FakeSSHAgent()
        agent = fake
        fake.identities = [(rejected.blob, "not on the server"), (accepted.blob, "on the server")]
        fake.signer = { blob, data in
            [rejected, accepted].first { $0.blob == blob }?.signatureBlob(for: data)
        }

        var connection = Connection(host: "127.0.0.1", port: port, username: NSUserName(), connectionProtocol: .sftp)
        connection.useSSHAgent = true
        let client = SFTPClient(
            connection: connection, password: "",
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true },
            agent: SSHAgent(socketPath: fake.socketPath)
        )
        try await client.connect()
        await client.disconnect()

        XCTAssertEqual(fake.signRequests.map(\.key), [accepted.blob],
                       "Only the key the server accepts may be signed with")
    }

    private func client(port: Int, agent fake: FakeSSHAgent) -> SFTPClient {
        var connection = Connection(host: "127.0.0.1", port: port, username: NSUserName(), connectionProtocol: .sftp)
        connection.useSSHAgent = true
        return SFTPClient(
            connection: connection, password: "",
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true },
            agent: SSHAgent(socketPath: fake.socketPath)
        )
    }

    func test_anAgentKeyTheServerDoesntKnow_isNeverSignedWith_andTheLoginStillFailsCleanly() async throws {
        let stranger = Key(), authorized = Key()
        let port = try startSSHD(authorizing: [authorized])
        let fake = try FakeSSHAgent()
        agent = fake
        fake.identities = [(stranger.blob, "not on the server")]
        fake.signer = { blob, data in stranger.blob == blob ? stranger.signatureBlob(for: data) : nil }

        do {
            try await client(port: port, agent: fake).connect()
            XCTFail("No credential the server accepts")
        } catch let error as RemoteClientError {
            switch error {
            case .authenticationFailed, .authenticationRejected: break
            default: XCTFail("\(error)")
            }
        }
        XCTAssertTrue(fake.signRequests.isEmpty)
    }

    /// SwiftNIO SSH's own server answers every plain key's query with PK_OK;
    /// the signed request that follows must go through.
    func test_aQueriedKey_isSignedAndAccepted_bySwiftNIOSSHsServer() async throws {
        let key = Key()
        let server = try FakeSSHServer(accepts: [.publicKey], reply: .accept)
        defer { server.stop() }
        let fake = try FakeSSHAgent()
        agent = fake
        fake.identities = [(key.blob, "laptop")]
        fake.signer = { _, data in key.signatureBlob(for: data) }

        // The fake server never gets as far as SFTP, so the connect is left
        // running: getting through authentication is what's being tested.
        let connecting = Task { try await client(port: server.port, agent: fake).connect() }
        defer { connecting.cancel() }
        for _ in 0..<100 where server.authenticationRequests == 0 {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(fake.signRequests.count, 1)
        XCTAssertEqual(server.authenticationRequests, 1, "The signed request should have followed PK_OK")
    }

    /// The user can still say no at the prompt (or the token be unplugged):
    /// that key is passed over and the next one tried, as before.
    func test_anAcceptedKeyTheAgentWontSignWith_isPassedOver_forTheNextOne() async throws {
        let declined = Key(), signed = Key()
        let port = try startSSHD(authorizing: [declined, signed])
        let fake = try FakeSSHAgent()
        agent = fake
        fake.identities = [(declined.blob, "user said no"), (signed.blob, "fine")]
        fake.signer = { blob, data in blob == signed.blob ? signed.signatureBlob(for: data) : nil }

        let client = client(port: port, agent: fake)
        try await client.connect()
        await client.disconnect()

        XCTAssertEqual(fake.signRequests.map(\.key), [declined.blob, signed.blob])
    }
}
