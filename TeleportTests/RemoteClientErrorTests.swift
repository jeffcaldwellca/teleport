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
}
