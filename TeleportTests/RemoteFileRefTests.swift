import XCTest
@testable import Teleport

final class RemoteFileRefTests: XCTestCase {

    /// The payload names the session it was dragged from, so a drop is
    /// handled against that server — never whichever tab is on screen.
    func test_roundTripsTheSessionItCameFrom() throws {
        let session = UUID()
        let ref = RemoteFileRef(remotePath: "/var/www/a.txt", fileName: "a.txt", isDirectory: false, sessionID: session)

        let decoded = try JSONDecoder().decode(RemoteFileRef.self, from: JSONEncoder().encode(ref))

        XCTAssertEqual(decoded.sessionID, session)
        XCTAssertEqual(decoded.remotePath, "/var/www/a.txt")
    }

    func test_payloadWithoutASession_stillDecodes() throws {
        let json = Data(#"{"remotePath":"/a","fileName":"a","isDirectory":true}"#.utf8)
        let decoded = try JSONDecoder().decode(RemoteFileRef.self, from: json)
        XCTAssertNil(decoded.sessionID)
        XCTAssertTrue(decoded.isDirectory)
    }
}
