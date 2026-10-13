import XCTest
import TeleportKit

final class FolderSyncPlanTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ path: String, size: Int64 = 100, at offset: TimeInterval = 0, seconds: Bool = true) -> SyncEntry {
        SyncEntry(relativePath: path, isDirectory: false, size: size,
                  modified: noon.addingTimeInterval(offset), modifiedHasSeconds: seconds)
    }
    private func dir(_ path: String) -> SyncEntry {
        SyncEntry(relativePath: path, isDirectory: true)
    }

    private func plan(
        local: [SyncEntry], remote: [SyncEntry], _ direction: SyncDirection = .upload,
        _ options: SyncOptions = SyncOptions()
    ) throws -> SyncPlan {
        try FolderSync.plan(local: local, remote: remote, direction: direction, options: options)
    }

    /// "kind path" for each action, in plan order.
    private func summary(_ plan: SyncPlan) -> [String] {
        plan.actions.map { "\($0.kind) \($0.relativePath)" }
    }

    // MARK: - What gets transferred

    func test_missingAtDestination_isTransferred() throws {
        let plan = try plan(local: [file("index.html")], remote: [])
        XCTAssertEqual(summary(plan), ["transfer index.html"])
        XCTAssertEqual(plan.totalBytes, 100)
    }

    func test_differentSize_isTransferred_evenWhenTheDestinationIsNewer() throws {
        let plan = try plan(local: [file("a.css", size: 120)], remote: [file("a.css", size: 100, at: 3600)])
        XCTAssertEqual(summary(plan), ["transfer a.css"])
    }

    func test_sameSize_sourceNewerBeyondTolerance_isTransferred() throws {
        let plan = try plan(local: [file("a.css", at: 10)], remote: [file("a.css")])
        XCTAssertEqual(summary(plan), ["transfer a.css"])
    }

    func test_sameSize_withinTolerance_orDestinationNewer_isInSync() throws {
        XCTAssertFalse(try plan(local: [file("a.css", at: 2)], remote: [file("a.css")]).hasChanges)
        XCTAssertFalse(try plan(local: [file("a.css")], remote: [file("a.css", at: 500)]).hasChanges)
    }

    /// FTP servers that only offer LIST report times to the minute. A file
    /// uploaded at 12:00:45 reads back as 12:00:00; treating that as "source
    /// is 45 s newer" would re-upload the whole site on every run.
    func test_minutePrecisionRemoteTime_usesTheWiderTolerance() throws {
        let inSync = try plan(local: [file("a.css", at: 45)], remote: [file("a.css", seconds: false)])
        XCTAssertFalse(inSync.hasChanges)

        let changed = try plan(local: [file("a.css", at: 300)], remote: [file("a.css", seconds: false)])
        XCTAssertEqual(summary(changed), ["transfer a.css"])
    }

    func test_sizeOnly_ignoresTimes() throws {
        let plan = try plan(local: [file("a.css", at: 9999)], remote: [file("a.css")], .upload,
                            SyncOptions(sizeOnly: true))
        XCTAssertFalse(plan.hasChanges)
    }

    func test_download_treatsTheRemoteSideAsTheSource() throws {
        let plan = try plan(
            local: [file("old.txt"), file("same.txt")],
            remote: [file("old.txt", at: 60), file("same.txt"), file("new.txt")],
            .download
        )
        XCTAssertEqual(summary(plan), ["transfer new.txt", "transfer old.txt"])
        XCTAssertEqual(plan.direction, .download)
    }

    // MARK: - Directories

    func test_missingDirectories_areCreated_parentsFirst_beforeTransfers() throws {
        let plan = try plan(
            local: [dir("css"), dir("css/vendor"), file("css/vendor/x.css"), file("index.html")],
            remote: []
        )
        XCTAssertEqual(summary(plan), [
            "createDirectory css", "createDirectory css/vendor",
            "transfer css/vendor/x.css", "transfer index.html",
        ])
    }

    // MARK: - Deletion

    func test_extraneous_isLeftAlone_unlessDeletionIsOn() throws {
        let local = [file("index.html")], remote = [file("index.html"), file("old.html")]

        XCTAssertFalse(try plan(local: local, remote: remote).hasChanges)

        let deleting = try plan(local: local, remote: remote, .upload, SyncOptions(deleteExtraneous: true))
        XCTAssertEqual(summary(deleting), ["delete old.html"])
    }

    func test_deletions_comeAfterTransfers_deepestFirst() throws {
        let plan = try plan(
            local: [file("index.html", size: 5)],
            remote: [file("index.html"), dir("old"), dir("old/img"), file("old/img/a.png"), file("old/b.html")],
            .upload, SyncOptions(deleteExtraneous: true)
        )
        XCTAssertEqual(summary(plan), [
            "transfer index.html",
            "delete old/img/a.png", "delete old/b.html", "delete old/img", "delete old",
        ])
    }

    /// An unmounted volume or a mistyped path looks like an empty folder.
    /// Mirroring "nothing" with deletion on would empty the server.
    func test_emptySource_withDeletion_isRefused_unlessExplicitlyAllowed() throws {
        let remote = [file("index.html")]
        XCTAssertThrowsError(try plan(local: [], remote: remote, .upload, SyncOptions(deleteExtraneous: true))) {
            XCTAssertEqual($0 as? FolderSyncError, .emptySourceWithDeletion)
        }
        // Only excluded files left counts as empty, too.
        XCTAssertThrowsError(try plan(local: [file(".DS_Store")], remote: remote, .upload,
                                      SyncOptions(deleteExtraneous: true)))

        let allowed = try plan(local: [], remote: remote, .upload,
                               SyncOptions(deleteExtraneous: true, allowEmptySource: true))
        XCTAssertEqual(summary(allowed), ["delete index.html"])
        // Without deletion an empty source is simply nothing to do.
        XCTAssertFalse(try plan(local: [], remote: remote).hasChanges)
    }

    // MARK: - Things that are never touched

    /// A file where the other side has a folder: replacing either would
    /// destroy something, so it's reported and left — with all its contents.
    func test_typeConflict_isSkipped_andNothingUnderItIsTouched() throws {
        let plan = try plan(
            local: [file("assets"), file("index.html")],
            remote: [dir("assets"), file("assets/logo.png"), dir("assets/fonts"), file("index.html")],
            .upload, SyncOptions(deleteExtraneous: true)
        )
        XCTAssertEqual(summary(plan), ["skip assets"])
        XCTAssertTrue(plan.actions[0].reason.contains("folder"), plan.actions[0].reason)
        XCTAssertFalse(plan.hasChanges)

        let reversed = try self.plan(
            local: [dir("assets"), file("assets/logo.png")], remote: [file("assets")], .upload,
            SyncOptions(deleteExtraneous: true)
        )
        XCTAssertEqual(summary(reversed), ["skip assets"])
    }

    func test_excluded_isNeitherTransferredNorDeleted_includingEverythingUnderIt() throws {
        let plan = try plan(
            local: [file(".DS_Store"), dir("node_modules"), file("node_modules/x.js"), file("debug.log"), file("app.js")],
            remote: [file("app.js"), dir("node_modules"), file("node_modules/y.js"), file("server.log"),
                     dir("cache"), file("cache/keep.log"), file("cache/stale.tmp")],
            .upload, SyncOptions(deleteExtraneous: true, excludes: ["node_modules", "*.log"])
        )
        // cache/stale.tmp goes; cache itself stays because an excluded file lives in it.
        XCTAssertEqual(summary(plan), ["delete cache/stale.tmp", "skip cache"])
    }

    func test_excludePatterns() {
        XCTAssertTrue(FolderSync.matches(exclude: "*.log", relativePath: "logs/app.log"))
        XCTAssertTrue(FolderSync.matches(exclude: "node_modules", relativePath: "web/node_modules/a/b.js"))
        XCTAssertFalse(FolderSync.matches(exclude: "node_modules", relativePath: "web/node_modules_old/a.js"))
        XCTAssertTrue(FolderSync.matches(exclude: "build/cache", relativePath: "build/cache/x.bin"))
        XCTAssertFalse(FolderSync.matches(exclude: "build/cache", relativePath: "src/build/cache/x.bin"))
        XCTAssertTrue(FolderSync.matches(exclude: "img/*.psd", relativePath: "img/hero.psd"))
        XCTAssertFalse(FolderSync.matches(exclude: "Makefile", relativePath: "makefile"), "Patterns are case-sensitive")
        XCTAssertTrue(FolderSync.matches(exclude: ".DS_Store", relativePath: "a/b/.DS_Store"))
    }

    // MARK: - Summary

    func test_planCounts() throws {
        let plan = try plan(
            local: [dir("css"), file("css/a.css", size: 30), file("b.js", size: 70), file("conflict")],
            remote: [file("gone.txt"), dir("conflict")],
            .upload, SyncOptions(deleteExtraneous: true)
        )
        XCTAssertEqual(plan.transfers.count, 2)
        XCTAssertEqual(plan.directories.count, 1)
        XCTAssertEqual(plan.deletions.count, 1)
        XCTAssertEqual(plan.skips.count, 1)
        XCTAssertEqual(plan.totalBytes, 100)
        XCTAssertTrue(plan.hasChanges)
    }
}
