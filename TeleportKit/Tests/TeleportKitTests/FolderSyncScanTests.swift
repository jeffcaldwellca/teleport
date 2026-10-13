import XCTest
import TeleportKit

final class FolderSyncScanTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(component: "teleport-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ contents: String = "x") throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func paths(_ entries: [SyncEntry]) -> [String] { entries.map(\.relativePath).sorted() }

    // MARK: - Local

    func test_scanLocal_listsFilesAndFoldersRelativeToTheRoot() throws {
        try write("index.html", "hello")
        try write("css/site.css")
        try write("css/vendor/x.css")

        let entries = try FolderSync.scanLocal(root)

        XCTAssertEqual(paths(entries), ["css", "css/site.css", "css/vendor", "css/vendor/x.css", "index.html"])
        let index = try XCTUnwrap(entries.first { $0.relativePath == "index.html" })
        XCTAssertEqual(index.size, 5)
        XCTAssertFalse(index.isDirectory)
        XCTAssertNotNil(index.modified)
        XCTAssertEqual(entries.first { $0.relativePath == "css" }?.isDirectory, true)
    }

    /// An excluded folder is reported (so the planner knows it is there and
    /// protects it) but not walked into.
    func test_scanLocal_reportsExcludedItemsButDoesNotDescend_andSkipsSymlinks() throws {
        try write("app.js")
        try write("node_modules/big/index.js")
        try write("debug.log")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "app.js"))

        let entries = try FolderSync.scanLocal(root, excludes: ["node_modules", "*.log"])

        XCTAssertEqual(paths(entries), ["app.js", "debug.log", "node_modules"])
    }

    func test_scanLocal_missingRoot_isAnError_notAnEmptyFolder() {
        let missing = root.appending(path: "nope")
        XCTAssertThrowsError(try FolderSync.scanLocal(missing)) {
            XCTAssertEqual($0 as? FolderSyncError, .sourceMissing(missing.path))
        }
        // As a destination that will be created, missing just means empty.
        XCTAssertEqual(try FolderSync.scanLocal(missing, missingRootIsEmpty: true), [])
    }

    func test_scanLocal_overTheLimit_throws() throws {
        for index in 0..<6 { try write("f\(index).txt") }
        XCTAssertThrowsError(try FolderSync.scanLocal(root, limit: 5)) {
            XCTAssertEqual($0 as? FolderSyncError, .tooLarge(limit: 5))
        }
    }

    // MARK: - Remote

    private let withSeconds = Date(timeIntervalSince1970: 1_700_000_045)
    private let onTheMinute = Date(timeIntervalSince1970: 1_700_000_040)

    private func remoteTree() -> TreeClient {
        TreeClient(tree: [
            "/var/www": [TreeClient.file("/var/www/index.html", size: 5, modified: withSeconds),
                         TreeClient.dir("/var/www/css"),
                         TreeClient.dir("/var/www/node_modules"),
                         TreeClient.file("/var/www/current", symlink: true)],
            "/var/www/css": [TreeClient.file("/var/www/css/site.css", modified: onTheMinute)],
            "/var/www/node_modules": [TreeClient.file("/var/www/node_modules/x.js")],
        ])
    }

    func test_scanRemote_walksTheTree_reportingExcludedFoldersWithoutDescending_andSkippingSymlinks() async throws {
        let entries = try await FolderSync.scanRemote(remoteTree(), root: "/var/www", excludes: ["node_modules"])

        XCTAssertEqual(paths(entries), ["css", "css/site.css", "index.html", "node_modules"])
        XCTAssertEqual(entries.first { $0.relativePath == "index.html" }?.size, 5)
    }

    func test_scanRemote_marksTimesThatCarryNoSeconds() async throws {
        let entries = try await FolderSync.scanRemote(remoteTree(), root: "/var/www")

        XCTAssertEqual(entries.first { $0.relativePath == "index.html" }?.modifiedHasSeconds, true)
        XCTAssertEqual(entries.first { $0.relativePath == "css/site.css" }?.modifiedHasSeconds, false)
    }

    func test_scanRemote_rootWithATrailingSlash_orTheServerRoot_stillYieldsRelativePaths() async throws {
        let client = TreeClient(tree: ["/": [TreeClient.file("/a.txt"), TreeClient.dir("/d")], "/d": [TreeClient.file("/d/b.txt")]])
        let fromRoot = try await FolderSync.scanRemote(client, root: "/")
        XCTAssertEqual(paths(fromRoot), ["a.txt", "d", "d/b.txt"])

        let trailing = try await FolderSync.scanRemote(remoteTree(), root: "/var/www/", excludes: ["node_modules"])
        XCTAssertEqual(paths(trailing), ["css", "css/site.css", "index.html", "node_modules"])
    }

    func test_scanRemote_missingRoot_throws_unlessItIsADestinationToBeCreated() async throws {
        do {
            _ = try await FolderSync.scanRemote(remoteTree(), root: "/nope")
            XCTFail("A missing source folder must be an error")
        } catch {}
        let asDestination = try await FolderSync.scanRemote(remoteTree(), root: "/nope", missingRootIsEmpty: true)
        XCTAssertEqual(asDestination, [])
    }

    func test_scanRemote_overTheLimit_throws() async {
        do {
            _ = try await FolderSync.scanRemote(remoteTree(), root: "/var/www", limit: 2)
            XCTFail("Expected the limit to stop the scan")
        } catch {
            XCTAssertEqual(error as? FolderSyncError, .tooLarge(limit: 2))
        }
    }

    // MARK: - Refining "newer" against imprecise listings

    /// FTP `LIST` gives times to the minute, in the server's own time zone.
    /// A file that merely *looks* older there is checked against the exact
    /// time before it is sent again — otherwise recently edited files would
    /// be re-uploaded on every run.
    func test_refine_dropsTransfersTheExactServerTimeShowsAreNotNewer() async throws {
        let edited = Date(timeIntervalSince1970: 1_700_003_600)
        let local = [SyncEntry(relativePath: "a.css", isDirectory: false, size: 10, modified: edited),
                     SyncEntry(relativePath: "b.css", isDirectory: false, size: 10, modified: edited)]
        // The listing shows both five hours "older" (a server five time zones away), to the minute.
        let listed = Date(timeIntervalSince1970: 1_700_003_600 - 5 * 3600)
        let remote = [SyncEntry(relativePath: "a.css", isDirectory: false, size: 10, modified: listed, modifiedHasSeconds: false),
                      SyncEntry(relativePath: "b.css", isDirectory: false, size: 10, modified: listed, modifiedHasSeconds: false)]
        let plan = try FolderSync.plan(local: local, remote: remote, direction: .upload)
        XCTAssertEqual(plan.transfers.map(\.relativePath), ["a.css", "b.css"])

        let client = TreeClient()
        client.preciseTimes = ["/site/a.css": edited.addingTimeInterval(30),      // really uploaded after the edit
                               "/site/b.css": edited.addingTimeInterval(-600)]    // really older

        let refined = await FolderSync.refine(plan, local: local, remote: remote, remoteRoot: "/site", client: client)

        XCTAssertEqual(refined.transfers.map(\.relativePath), ["b.css"])
    }

    func test_refine_leavesPreciseListingsAndOtherReasonsAlone_withoutAskingTheServer() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_045)
        let local = [SyncEntry(relativePath: "newer.css", isDirectory: false, size: 10, modified: now.addingTimeInterval(100)),
                     SyncEntry(relativePath: "bigger.css", isDirectory: false, size: 20, modified: now),
                     SyncEntry(relativePath: "new.css", isDirectory: false, size: 5, modified: now)]
        let remote = [SyncEntry(relativePath: "newer.css", isDirectory: false, size: 10, modified: now),
                      SyncEntry(relativePath: "bigger.css", isDirectory: false, size: 10, modified: now)]
        let plan = try FolderSync.plan(local: local, remote: remote, direction: .upload)
        let client = TreeClient()

        let refined = await FolderSync.refine(plan, local: local, remote: remote, remoteRoot: "/site", client: client)

        XCTAssertEqual(refined, plan)
        XCTAssertTrue(client.calls.isEmpty, "\(client.calls)")
    }
}
