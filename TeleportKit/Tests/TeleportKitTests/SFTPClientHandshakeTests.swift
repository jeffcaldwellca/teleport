import XCTest
import NIOSSH
@testable import TeleportKit

/// Transport negotiation against server policies seen on hardened hosts.
final class SFTPClientHandshakeTests: XCTestCase {

    /// A server hardened the way ssh-audit and most VPS guides recommend:
    /// only encrypt-then-MAC MAC names. AES-GCM never uses the MAC, but a
    /// name still has to be agreed on, and SwiftNIO SSH only ever offered
    /// `hmac-sha2-256` — so such servers couldn't be reached at all.
    private final class EncryptThenMACOnlyAES256GCM: AES256GCMOpenSSH {
        override class var macNames: [String] {
            ["hmac-sha2-512-etm@openssh.com", "hmac-sha2-256-etm@openssh.com", "umac-128-etm@openssh.com"]
        }
    }

    private var server: FakeSSHServer?

    override func tearDown() {
        server?.stop()
        super.tearDown()
    }

    private func client(to server: FakeSSHServer) -> SFTPClient {
        SFTPClient(
            connection: Connection(name: "fake", host: "127.0.0.1", port: server.port,
                                   username: "alice", connectionProtocol: .sftp),
            password: "secret",
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true },
            agent: nil
        )
    }

    func test_reachesAuthentication_onServerOfferingOnlyEncryptThenMACNames() async throws {
        let server = try FakeSSHServer(accepts: [.password], reply: .reject,
                                       transportProtectionSchemes: [EncryptThenMACOnlyAES256GCM.self])
        self.server = server
        do {
            try await client(to: server).connect()
            XCTFail("The fake server refuses every login")
        } catch RemoteClientError.authenticationFailed {
            // A refused password proves the handshake got all the way to authentication.
        }
    }
}
