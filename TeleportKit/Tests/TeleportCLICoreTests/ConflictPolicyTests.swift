import XCTest
@testable import TeleportCLICore

final class ConflictPolicyTests: XCTestCase {
    func test_noConflict_alwaysProceeds() {
        XCTAssertEqual(
            decideConflict(policy: .skip, exists: false, localDate: nil, remoteDate: nil, direction: .get),
            .proceed
        )
    }

    func test_overwrite_alwaysProceeds() {
        XCTAssertEqual(
            decideConflict(policy: .overwrite, exists: true, localDate: nil, remoteDate: nil, direction: .get),
            .proceed
        )
    }

    func test_skip_alwaysSkips() {
        XCTAssertEqual(
            decideConflict(policy: .skip, exists: true, localDate: Date(), remoteDate: Date(), direction: .put),
            .skip
        )
    }

    func test_ifNewer_get_proceedsWhenRemoteIsNewer() {
        let older = Date(timeIntervalSince1970: 0)
        let newer = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: older, remoteDate: newer, direction: .get),
            .proceed
        )
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: newer, remoteDate: older, direction: .get),
            .skip
        )
    }

    func test_ifNewer_put_proceedsWhenLocalIsNewer() {
        let older = Date(timeIntervalSince1970: 0)
        let newer = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: newer, remoteDate: older, direction: .put),
            .proceed
        )
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: older, remoteDate: newer, direction: .put),
            .skip
        )
    }

    func test_ifNewer_missingDates_skips() {
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: nil, remoteDate: nil, direction: .get),
            .skip
        )
    }
}
