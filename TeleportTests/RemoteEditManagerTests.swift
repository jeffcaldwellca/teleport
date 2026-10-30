import XCTest
import TeleportKit
@testable import Teleport

@MainActor
final class RemoteEditManagerTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "teleport-edit-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeCopy(in base: URL) throws -> URL {
        let folder = base.appending(component: "Edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(component: "index.html")
        try Data("x".utf8).write(to: file)
        return file
    }

    private func makeBase() -> URL {
        let base = FileManager.default.temporaryDirectory.appending(component: "teleport-edit-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    /// Editing the same file again must reopen the copy already open, not
    /// make a second one whose editor could later save older content over it.
    func test_editingTheSameRemoteFileAgain_findsTheOpenCopy() throws {
        let manager = RemoteEditManager(defaults: defaults)
        let connection = Connection(host: "example.com")
        let copy = try makeCopy(in: makeBase())
        manager.beginEditing(localURL: copy, connection: connection, remotePath: "/site/index.html")

        XCTAssertEqual(manager.existingCopy(connectionID: connection.id, remotePath: "/site/index.html"), copy)
        XCTAssertNil(manager.existingCopy(connectionID: connection.id, remotePath: "/other.html"))
        XCTAssertNil(manager.existingCopy(connectionID: UUID(), remotePath: "/site/index.html"))
    }

    /// A copy still open in an editor from the last run keeps being watched,
    /// and the launch sweep leaves its folder alone; a long-idle one goes.
    func test_aSessionFromTheLastRun_survivesTheLaunchSweep() throws {
        let base = makeBase()
        let recent = try makeCopy(in: base)
        let stale = try makeCopy(in: base)
        let earlier = RemoteEditManager(defaults: defaults)
        earlier.beginEditing(localURL: recent, connection: Connection(host: "a"), remotePath: "/a.html")
        earlier.beginEditing(localURL: stale, connection: Connection(host: "b"), remotePath: "/b.html")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-RemoteEditManager.maximumIdle - 60)],
            ofItemAtPath: stale.path
        )

        let relaunched = RemoteEditManager(defaults: defaults)
        let keep = relaunched.restore()
        TemporaryFiles.sweepStale(in: base, keeping: keep)

        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
    }
}
