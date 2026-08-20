import XCTest
import TeleportKit

final class RemoteClientErrorTests: XCTestCase {
    func test_hostKeyMismatch_usesPrettyPrintedFingerprints() {
        let error = RemoteClientError.hostKeyMismatch(
            host: "example.com", port: 22,
            expected: "SHA256:aabbccdd", actual: "SHA256:11223344"
        )
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("SHA256:aa:bb:cc:dd"), message)
        XCTAssertTrue(message.contains("SHA256:11:22:33:44"), message)
        XCTAssertTrue(message.lowercased().contains("remove the stored host key"), message)
    }

    func test_hostKeyUntrusted_usesPrettyPrintedFingerprint() {
        let error = RemoteClientError.hostKeyUntrusted(
            host: "example.com", port: 22, fingerprint: "SHA256:aabbccdd"
        )
        let message = error.errorDescription ?? ""
        XCTAssertTrue(message.contains("SHA256:aa:bb:cc:dd"), message)
    }

    /// A failed TCP connect surfaces through SwiftNIO as `NIOConnectionError`,
    /// which is `CustomStringConvertible` but *not* `LocalizedError`. The GUI
    /// renders every error with `localizedDescription`, so an unmapped NIO
    /// error reaches the user as "The operation couldn't be completed.
    /// (NIOPosix.NIOConnectionError error 1.)" — no host, no port, no reason.
    func test_sftpConnectFailure_producesHumanReadableMessage() async {
        let connection = Connection(
            name: "dead", host: "127.0.0.1", port: 59999,
            username: "nobody", connectionProtocol: .sftp
        )
        let client = SFTPClient(connection: connection, password: "unused")

        do {
            try await client.connect()
            XCTFail("Expected connect to a closed port to fail")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(
                message.contains("couldn't be completed"),
                "Raw NIO error leaked to the user: \(message)"
            )
            XCTAssertTrue(message.contains("127.0.0.1"), message)
            XCTAssertTrue(message.contains("59999"), message)
        }
    }
}
