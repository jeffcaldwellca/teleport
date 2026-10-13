import XCTest
import TeleportKit
@testable import Teleport

/// An in-memory remote tree that records what is done to it.
private final class RecordingTreeClient: RemoteClient, @unchecked Sendable {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        func record(_ call: String) { lock.withLock { _calls.append(call) } }
        var calls: [String] { lock.withLock { _calls } }
        func calls(starting prefix: String) -> [String] { calls.filter { $0.hasPrefix(prefix) } }
    }

    let tree: [String: [FileItem]]
    let log: Log
    let failingUploads: Set<String>
    init(tree: [String: [FileItem]], log: Log, failingUploads: Set<String> = []) {
        self.tree = tree; self.log = log; self.failingUploads = failingUploads
    }

    func listDirectory(at absolutePath: String) async throws -> [FileItem] {
        guard let entries = tree[absolutePath] else { throw RemoteClientError.fileNotFound(absolutePath) }
        return entries
    }
    func createDirectory(at absolutePath: String) async throws { log.record("mkdir \(absolutePath)") }
    func delete(at absolutePath: String, isDirectory: Bool) async throws {
        log.record("\(isDirectory ? "rmdir" : "rm") \(absolutePath)")
    }
    func upload(from localURL: URL, remotePath: String, resume: Bool,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        // A refusal the queue treats as final, so the test needn't sit through retries.
        if failingUploads.contains(remotePath) { throw RemoteClientError.authenticationRejected("scripted") }
        log.record("upload \(remotePath)")
    }
    func download(remotePath: String, to localURL: URL, resume: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        log.record("download \(remotePath)")
        try Data("from server".utf8).write(to: localURL)
    }
    func connect() async throws {}
    func disconnect() async {}
    func keepAlive() async {}
    func ping() async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(_ octal: Int, at absolutePath: String) async throws {}
    func setOwnership(owner: String, group: String, at absolutePath: String) async throws {}
    func remoteModifiedDate(at remotePath: String) async -> Date? { nil }
    func setModifiedDate(_ date: Date, at remotePath: String) async {}
    /// As a real server would answer: a file in the tree exists.
    func fileExists(at remotePath: String) async -> Bool {
        tree.values.contains { $0.contains { $0.path == remotePath } }
    }
}

@MainActor
final class SyncViewModelTests: XCTestCase {

    private var localRoot: URL!
    private var log: RecordingTreeClient.Log!
    private var queue: TransferQueueViewModel!
    private var trashed: [String] = []
    private let connection = Connection(name: "Site", host: "example.invalid")

    private func file(_ path: String, size: Int64 = 3) -> FileItem {
        FileItem(name: (path as NSString).lastPathComponent, path: path, isDirectory: false, size: size,
                 // Later than anything the tests write locally, so an equal-sized
                 // local file reads as "already in sync" rather than "newer".
                 modifiedDate: Date(timeIntervalSince1970: 4_000_000_045))
    }
    private func dir(_ path: String) -> FileItem {
        FileItem(name: (path as NSString).lastPathComponent, path: path, isDirectory: true)
    }

    override func setUp() async throws {
        localRoot = FileManager.default.temporaryDirectory.appending(component: "teleport-syncvm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        log = RecordingTreeClient.Log()
        trashed = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: localRoot)
    }

    private func write(_ relative: String, _ contents: String = "abc") throws {
        let url = localRoot.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func makeModel(remote tree: [String: [FileItem]], failingUploads: Set<String> = []) -> SyncViewModel {
        let log = self.log!
        queue = TransferQueueViewModel(
            passwordProvider: { _ in "" },
            clientFactory: { _, _ in RecordingTreeClient(tree: tree, log: log, failingUploads: failingUploads) }
        )
        return SyncViewModel(connection: connection, localRoot: localRoot, remoteRoot: "/var/www", queue: queue,
                             trash: { [unowned self] in trashed.append($0.lastPathComponent) })
    }

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Compare

    func test_compare_producesAPlan_withoutChangingAnything() async throws {
        try write("index.html")
        try write("css/site.css")
        let model = makeModel(remote: ["/var/www": [file("/var/www/index.html"), file("/var/www/old.html")]])

        await model.compare()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.plan?.transfers.map(\.relativePath), ["css/site.css"])
        XCTAssertEqual(model.plan?.directories.map(\.relativePath), ["css"])
        XCTAssertEqual(model.plan?.deletions.count, 0)
        XCTAssertTrue(log.calls.isEmpty, "\(log.calls)")
        XCTAssertTrue(queue.tasks.isEmpty)
    }

    func test_compare_failure_isReported() async {
        try? FileManager.default.removeItem(at: localRoot)      // the source folder is gone
        let model = makeModel(remote: ["/var/www": []])

        await model.compare()

        guard case .failed(let message) = model.phase else { return XCTFail("Expected failure, got \(model.phase)") }
        XCTAssertTrue(message.contains("exist"), message)
        XCTAssertNil(model.plan)
    }

    func test_changingAnOption_discardsTheStalePlan() async throws {
        try write("index.html")
        let model = makeModel(remote: ["/var/www": [file("/var/www/old.html")]])
        await model.compare()
        XCTAssertNotNil(model.plan)

        model.deleteExtraneous = true

        XCTAssertNil(model.plan, "A plan made under other settings must not be applied")
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: - Apply

    func test_apply_upload_createsFolders_andQueuesTransfersThatOverwriteWithoutAsking() async throws {
        try write("index.html", "changed!")
        try write("css/site.css")
        let model = makeModel(remote: ["/var/www": [file("/var/www/index.html")]])
        await model.compare()

        await model.apply()

        XCTAssertEqual(log.calls(starting: "mkdir"), ["mkdir /var/www", "mkdir /var/www/css"])
        XCTAssertEqual(queue.tasks.map(\.remotePath).sorted(), ["/var/www/css/site.css", "/var/www/index.html"])
        XCTAssertTrue(queue.tasks.allSatisfy { $0.direction == .upload && $0.conflictBehavior == .overwrite })
        guard case .done = model.phase else { return XCTFail("Expected done, got \(model.phase)") }
        try await waitUntil("uploads") { self.queue.tasks.allSatisfy { $0.status == .completed } }
        XCTAssertEqual(log.calls(starting: "upload").sorted(), ["upload /var/www/css/site.css", "upload /var/www/index.html"])
        XCTAssertTrue(log.calls(starting: "rm").isEmpty)
    }

    /// The files being replaced exist on the server — the case where the
    /// queue would normally stop and ask. A sync has already decided.
    func test_apply_overwritesExistingFiles_withoutRaisingAConflict() async throws {
        let savedConflict = Preferences.shared.defaultConflict
        Preferences.shared.defaultConflict = .ask
        defer { Preferences.shared.defaultConflict = savedConflict }
        try write("index.html", "changed, and longer")
        let model = makeModel(remote: ["/var/www": [file("/var/www/index.html")]])
        await model.compare()

        await model.apply()

        try await waitUntil("upload or a conflict prompt") {
            self.queue.pendingConflict != nil || self.queue.tasks.allSatisfy { $0.status.isFinal }
        }
        XCTAssertNil(queue.pendingConflict)
        XCTAssertEqual(queue.tasks.map(\.status), [.completed])
        XCTAssertEqual(log.calls(starting: "upload"), ["upload /var/www/index.html"])
    }

    /// Deleting first and transferring later would, if a transfer then
    /// failed, leave the destination with neither the old file nor the new.
    func test_apply_deletesOnlyAfterTheTransfersHaveSucceeded() async throws {
        try write("index.html")
        try write("home.html", "renamed page")
        let model = makeModel(remote: ["/var/www": [file("/var/www/index.html"), file("/var/www/old.html")]])
        model.deleteExtraneous = true
        await model.compare()

        await model.apply()

        XCTAssertEqual(queue.tasks.map(\.status), [.completed], "Deletions waited for the upload")
        let calls = log.calls.filter { $0.hasPrefix("upload") || $0.hasPrefix("rm") }
        XCTAssertEqual(calls, ["upload /var/www/home.html", "rm /var/www/old.html"])
        guard case .done = model.phase else { return XCTFail("Expected done, got \(model.phase)") }
    }

    func test_apply_whenATransferFails_deletesNothing_andSaysSo() async throws {
        try write("index.html")
        try write("home.html", "renamed page")
        let model = makeModel(
            remote: ["/var/www": [file("/var/www/index.html"), file("/var/www/old.html")]],
            failingUploads: ["/var/www/home.html"]
        )
        model.deleteExtraneous = true
        await model.compare()

        await model.apply()

        XCTAssertTrue(log.calls(starting: "rm").isEmpty, "\(log.calls)")
        guard case .done(let message) = model.phase else { return XCTFail("Expected done, got \(model.phase)") }
        XCTAssertTrue(message.lowercased().contains("nothing was deleted"), message)
    }

    func test_apply_deletionsCanBeCalledOffWhileTransfersAreStillRunning() async throws {
        try write("index.html")
        try write("home.html", "renamed page")
        let model = makeModel(remote: ["/var/www": [file("/var/www/index.html"), file("/var/www/old.html")]])
        model.deleteExtraneous = true
        await model.compare()

        model.skipDeletions()          // e.g. pressed while the queue is still working
        await model.apply()

        // The transfers carry on regardless; only the deletions are dropped.
        try await waitUntil("upload") { self.queue.tasks.allSatisfy { $0.status == .completed } }
        XCTAssertEqual(log.calls(starting: "upload"), ["upload /var/www/home.html"])
        XCTAssertTrue(log.calls(starting: "rm").isEmpty)
    }

    func test_apply_withDeletion_removesWhatIsNotInTheSource_deepestFirst() async throws {
        try write("index.html")
        let model = makeModel(remote: [
            "/var/www": [file("/var/www/index.html"), dir("/var/www/old")],
            "/var/www/old": [file("/var/www/old/a.html")],
        ])
        model.deleteExtraneous = true
        await model.compare()
        XCTAssertEqual(model.plan?.deletions.count, 2)

        await model.apply()

        XCTAssertEqual(log.calls.filter { $0.hasPrefix("rm") }, ["rm /var/www/old/a.html", "rmdir /var/www/old"])
        XCTAssertTrue(queue.tasks.isEmpty)
    }

    func test_apply_download_createsLocalFolders_queuesDownloads_andTrashesWhatIsNotOnTheServer() async throws {
        try write("stale.txt")
        let model = makeModel(remote: [
            "/var/www": [file("/var/www/index.html"), dir("/var/www/css")],
            "/var/www/css": [file("/var/www/css/site.css")],
        ])
        model.direction = .download
        model.deleteExtraneous = true
        await model.compare()

        await model.apply()

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: localRoot.appending(path: "css").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(queue.tasks.map(\.remotePath).sorted(), ["/var/www/css/site.css", "/var/www/index.html"])
        XCTAssertTrue(queue.tasks.allSatisfy { $0.direction == .download && $0.conflictBehavior == .overwrite })
        XCTAssertEqual(trashed, ["stale.txt"])
        try await waitUntil("downloads") { self.queue.tasks.allSatisfy { $0.status == .completed } }
        XCTAssertEqual(try String(contentsOf: localRoot.appending(path: "css/site.css"), encoding: .utf8), "from server")
    }

    func test_apply_doesNothingWithoutACurrentPlan() async throws {
        try write("index.html")
        let model = makeModel(remote: ["/var/www": []])

        await model.apply()

        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertTrue(queue.tasks.isEmpty)
    }
}
