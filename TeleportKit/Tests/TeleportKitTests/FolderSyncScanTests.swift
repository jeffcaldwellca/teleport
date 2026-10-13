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
    func test_scanLocal_reportsExcludedItemsAndLinks_butDoesNotDescendIntoEither() throws {
        try write("app.js")
        try write("node_modules/big/index.js")
        try write("debug.log")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: root.appending(path: "app.js"))

        let entries = try FolderSync.scanLocal(root, excludes: ["node_modules", "*.log"])

        XCTAssertEqual(paths(entries), ["app.js", "debug.log", "link", "node_modules"])
        XCTAssertEqual(entries.filter(\.isOpaque).map(\.relativePath), ["link"])
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

    func test_scanRemote_walksTheTree_reportingExcludedFoldersAndLinksWithoutDescending() async throws {
        let entries = try await FolderSync.scanRemote(remoteTree(), root: "/var/www", excludes: ["node_modules"])

        XCTAssertEqual(paths(entries), ["css", "css/site.css", "current", "index.html", "node_modules"])
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
        XCTAssertEqual(paths(trailing), ["css", "css/site.css", "current", "index.html", "node_modules"])
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

    // MARK: - Review: scanning must not under-report

    /// A folder that can't be read is not an empty folder. Reporting it as
    /// one would have a sync-with-delete remove everything under it on the
    /// other side.
    func test_scanLocal_unreadableSubfolder_abortsTheScan() throws {
        try write("public/index.html")
        try write("private/secret.txt")
        let locked = root.appending(path: "private")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        XCTAssertThrowsError(try FolderSync.scanLocal(root)) { error in
            guard case .unreadable(let path)? = error as? FolderSyncError else {
                return XCTFail("Expected .unreadable, got \(error)")
            }
            XCTAssertTrue(path.contains("private"), path)
        }
    }

    func test_scanLocal_reportsSymlinksAsOpaque_withoutFollowingThem() throws {
        try write("releases/3/app.js")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "current"),
                                                   withDestinationURL: root.appending(path: "releases/3"))

        let entries = try FolderSync.scanLocal(root)

        let link = try XCTUnwrap(entries.first { $0.relativePath == "current" })
        XCTAssertTrue(link.isOpaque)
        XCTAssertFalse(entries.contains { $0.relativePath.hasPrefix("current/") })
    }

    func test_scanRemote_reportsSymlinksAsOpaque() async throws {
        let entries = try await FolderSync.scanRemote(remoteTree(), root: "/var/www", excludes: ["node_modules"])
        XCTAssertEqual(entries.first { $0.relativePath == "current" }?.isOpaque, true)
    }

    /// "Couldn't list it" is only "it isn't there yet" when the parent
    /// folder agrees. A permission error or a timeout on an existing folder
    /// must not be read as an empty destination.
    func test_scanRemote_rootThatExistsButCannotBeListed_isAnError_evenAsADestination() async throws {
        let client = TreeClient(tree: ["/var": [TreeClient.dir("/var/www")]])   // /var/www exists, listing it fails
        do {
            _ = try await FolderSync.scanRemote(client, root: "/var/www", missingRootIsEmpty: true)
            XCTFail("An existing folder that can't be listed is not empty")
        } catch {}

        let absent = try await FolderSync.scanRemote(client, root: "/var/new-site", missingRootIsEmpty: true)
        XCTAssertEqual(absent, [])
    }

    // MARK: - Refining against exact times

    private func coarse(_ path: String, _ time: Date) -> SyncEntry {
        SyncEntry(relativePath: path, isDirectory: false, size: 10, modified: time, modifiedHasSeconds: false)
    }
    private func precise(_ path: String, _ time: Date) -> SyncEntry {
        SyncEntry(relativePath: path, isDirectory: false, size: 10, modified: time)
    }

    /// The listing shows the server's files five hours "older" (a server five
    /// time zones away). The exact times settle each one.
    func test_refine_dropsTransfersTheExactServerTimeShowsAreNotNewer() async throws {
        let edited = Date(timeIntervalSince1970: 1_700_003_600)
        let listed = edited.addingTimeInterval(-5 * 3600)
        let local = [precise("a.css", edited), precise("b.css", edited)]
        let remote = [coarse("a.css", listed), coarse("b.css", listed)]
        let plan = try FolderSync.plan(local: local, remote: remote, direction: .upload)
        XCTAssertEqual(plan.transfers.map(\.relativePath), ["a.css", "b.css"])

        let client = TreeClient()
        client.preciseTimes = ["/site/a.css": edited.addingTimeInterval(30),      // really uploaded after the edit
                               "/site/b.css": edited.addingTimeInterval(-600)]    // really older

        let refined = await FolderSync.refine(plan, local: local, remote: remote, remoteRoot: "/site", client: client)

        XCTAssertEqual(refined.transfers.map(\.relativePath), ["b.css"])
        XCTAssertTrue(refined.uncertain.isEmpty)
    }

    /// The other way round: the listing makes the server's copy look ten
    /// hours *newer* (a server ahead of UTC), hiding a same-size local edit.
    func test_refine_addsTransfersTheListingHid() async throws {
        let edited = Date(timeIntervalSince1970: 1_700_003_600)
        let local = [precise("a.css", edited)]
        let remote = [coarse("a.css", edited.addingTimeInterval(9 * 3600))]
        let plan = try FolderSync.plan(local: local, remote: remote, direction: .upload)
        XCTAssertTrue(plan.transfers.isEmpty)

        let client = TreeClient()
        client.preciseTimes = ["/site/a.css": edited.addingTimeInterval(-3600)]   // really an hour older than the edit

        let refined = await FolderSync.refine(plan, local: local, remote: remote, remoteRoot: "/site", client: client)

        XCTAssertEqual(refined.transfers.map(\.relativePath), ["a.css"])
        XCTAssertEqual(refined.transfers.first?.reason, "newer")
    }

    func test_refine_asksNothingWhenTheListingIsExact_orTheServerCannotSay() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_045)
        let local = [precise("newer.css", now.addingTimeInterval(100)), precise("new.css", now)]
        let remote = [precise("newer.css", now)]
        let plan = try FolderSync.plan(local: local, remote: remote, direction: .upload)
        let client = TreeClient()

        let refined = await FolderSync.refine(plan, local: local, remote: remote, remoteRoot: "/site", client: client)

        XCTAssertEqual(refined, plan)
        XCTAssertTrue(client.calls.isEmpty, "\(client.calls)")

        // No exact time available (no MDTM): the listing's verdict stands.
        let coarsePlan = try FolderSync.plan(local: [precise("a.css", now.addingTimeInterval(3600))],
                                             remote: [coarse("a.css", now)], direction: .upload)
        let unchanged = await FolderSync.refine(coarsePlan, local: [precise("a.css", now.addingTimeInterval(3600))],
                                                remote: [coarse("a.css", now)], remoteRoot: "/site", client: client)
        XCTAssertEqual(unchanged.transfers.map(\.relativePath), ["a.css"])
    }
}
