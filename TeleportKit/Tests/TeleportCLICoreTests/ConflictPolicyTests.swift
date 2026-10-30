import XCTest
import TeleportKit
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

    /// FTP's MDTM only reports whole seconds; a local file's mtime carries
    /// sub-second precision. Without flooring, an unchanged file compares as
    /// "local is newer" on every single run and gets needlessly re-uploaded.
    func test_ifNewer_put_sameSecondDifferentFraction_skips() {
        let localWithFraction = Date(timeIntervalSince1970: 1000.732)
        let remoteTruncated = Date(timeIntervalSince1970: 1000.0)
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: localWithFraction, remoteDate: remoteTruncated, direction: .put),
            .skip
        )
    }

    func test_ifNewer_put_genuinelyNewerSecond_proceeds() {
        let local = Date(timeIntervalSince1970: 1001.0)
        let remote = Date(timeIntervalSince1970: 1000.0)
        XCTAssertEqual(
            decideConflict(policy: .ifNewer, exists: true, localDate: local, remoteDate: remote, direction: .put),
            .proceed
        )
    }

    /// `get`/`put --recursive`, `sync` and the app's folder transfers should
    /// all give up at the same size.
    func test_recursiveTransferLimit_matchesSync() {
        XCTAssertEqual(FolderWalk.defaultLimit, FolderSync.defaultLimit)
    }

    /// With --resume the existing destination is the partial copy to finish.
    func test_resume_proceedsDespiteTheSkipPolicy() {
        XCTAssertEqual(
            decideConflict(policy: .skip, exists: true, localDate: nil, remoteDate: nil, direction: .put, resume: true),
            .proceed
        )
    }

    func test_get_intoAnExistingFolder_writesTheFileInsideIt() throws {
        let dir = FileManager.default.temporaryDirectory.appending(component: "tport-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(downloadDestination(remotePath: "/srv/f.txt", local: dir.path).lastPathComponent, "f.txt")
        XCTAssertEqual(downloadDestination(remotePath: "/srv/f.txt", local: dir.path + "/g.txt").lastPathComponent, "g.txt")
        XCTAssertEqual(downloadDestination(remotePath: "/srv/f.txt", local: "/nonexistent/new/").path, "/nonexistent/new/f.txt")
    }

    func test_put_toAFolderURL_writesTheFileInsideIt() {
        let local = URL(fileURLWithPath: "/tmp/f.txt")
        XCTAssertEqual(uploadDestination(localURL: local, remotePath: "/srv/"), "/srv/f.txt")
        XCTAssertEqual(uploadDestination(localURL: local, remotePath: "/srv/g.txt"), "/srv/g.txt")
    }
}
