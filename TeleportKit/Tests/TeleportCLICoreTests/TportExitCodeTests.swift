import XCTest
import TeleportKit
@testable import TeleportCLICore

final class TportExitCodeTests: XCTestCase {
    func test_map_usageError() {
        XCTAssertEqual(TportExitCode.map(TportUsageError.invalidURL("x")), .usage)
    }

    func test_map_authFailure() {
        XCTAssertEqual(TportExitCode.map(RemoteClientError.authenticationFailed), .authFailed)
        XCTAssertEqual(TportExitCode.map(RemoteClientError.permissionDenied), .authFailed)
    }

    func test_map_notFound() {
        XCTAssertEqual(TportExitCode.map(RemoteClientError.fileNotFound("/x")), .notFound)
    }

    func test_map_notConnected() {
        XCTAssertEqual(TportExitCode.map(RemoteClientError.notConnected), .connectionFailed)
    }

    func test_map_hostKeyCases() {
        XCTAssertEqual(
            TportExitCode.map(RemoteClientError.hostKeyUntrusted(host: "h", port: 22, fingerprint: "f")),
            .hostKey
        )
        XCTAssertEqual(
            TportExitCode.map(RemoteClientError.hostKeyMismatch(host: "h", port: 22, expected: "a", actual: "b")),
            .hostKey
        )
    }

    func test_map_ftpAuthFailed() {
        XCTAssertEqual(TportExitCode.map(FTPError.authFailed), .authFailed)
    }

    func test_map_ftpConnectionFailed() {
        XCTAssertEqual(TportExitCode.map(FTPError.connectionFailed("x")), .connectionFailed)
    }

    func test_map_unknownErrorFallsBackToGeneralFailure() {
        struct SomeOtherError: Error {}
        XCTAssertEqual(TportExitCode.map(SomeOtherError()), .generalFailure)
    }
}
