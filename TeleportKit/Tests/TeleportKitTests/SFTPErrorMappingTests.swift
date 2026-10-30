import XCTest
@testable import Citadel
@testable import TeleportKit

/// The server's SFTP status answers must reach the app as `RemoteClientError`,
/// which is what it uses to tell "refused" from "connection dropped".
final class SFTPErrorMappingTests: XCTestCase {

    private func status(_ code: SFTPStatusCode, _ message: String = "") -> SFTPMessage.Status {
        SFTPMessage.Status(requestId: 1, errorCode: code, message: message, languageTag: "en")
    }

    func test_permissionDenied_isPermissionDenied() {
        let mapped = TeleportKit.SFTPClient.mapped(status(.permissionDenied, "Permission denied"), path: "/root")
        guard case RemoteClientError.permissionDenied = mapped else { return XCTFail("\(mapped)") }
    }

    func test_noSuchFile_namesThePath() {
        let mapped = TeleportKit.SFTPClient.mapped(SFTPError.errorStatus(status(.noSuchFile)), path: "/gone")
        guard case RemoteClientError.fileNotFound(let path) = mapped else { return XCTFail("\(mapped)") }
        XCTAssertEqual(path, "/gone")
    }

    func test_otherRefusals_keepTheServersMessage() {
        let mapped = TeleportKit.SFTPClient.mapped(status(.failure, "File exists"), path: "/a")
        guard case RemoteClientError.serverRefused(let message) = mapped else { return XCTFail("\(mapped)") }
        XCTAssertEqual(message, "File exists")
    }

    func test_errorsThatArentServerAnswers_passThrough() {
        let mapped = TeleportKit.SFTPClient.mapped(SFTPError.connectionClosed, path: "/a")
        guard case SFTPError.connectionClosed = mapped else { return XCTFail("\(mapped)") }
    }
}
