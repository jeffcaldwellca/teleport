import XCTest
import TeleportKit
@testable import TeleportCLICore

final class RemoteTargetTests: XCTestCase {
    func test_parse_sftpWithUserAndPort() throws {
        let t = try RemoteTarget.parse("sftp://alice@example.com:2222/var/www")
        XCTAssertEqual(t.connectionProtocol, .sftp)
        XCTAssertEqual(t.username, "alice")
        XCTAssertEqual(t.host, "example.com")
        XCTAssertEqual(t.port, 2222)
        XCTAssertEqual(t.path, "/var/www")
    }

    func test_parse_defaultsPortFromProtocol() throws {
        let t = try RemoteTarget.parse("ftp://example.com/pub")
        XCTAssertEqual(t.port, 21)
    }

    func test_parse_defaultsPathToRoot() throws {
        let t = try RemoteTarget.parse("sftp://example.com")
        XCTAssertEqual(t.path, "/")
    }

    func test_parse_rejectsUnsupportedScheme() {
        XCTAssertThrowsError(try RemoteTarget.parse("http://example.com/")) { error in
            XCTAssertTrue(error is TportUsageError)
        }
    }

    func test_parse_rejectsMissingHost() {
        XCTAssertThrowsError(try RemoteTarget.parse("sftp:///path")) { error in
            XCTAssertTrue(error is TportUsageError)
        }
    }

    func test_parse_ftpsDefaultsPort21() throws {
        let t = try RemoteTarget.parse("ftps://example.com/pub")
        XCTAssertEqual(t.port, 21)
        XCTAssertEqual(t.connectionProtocol, .ftps)
    }
}
