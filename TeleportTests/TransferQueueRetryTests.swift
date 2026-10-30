import XCTest
import TeleportKit
@testable import Teleport

/// Scripted `RemoteClient`: fails its first `failingConnects` connection
/// attempts (shared across instances, as the queue makes a client per
/// attempt) and records how uploads were requested.
private final class ScriptedClient: RemoteClient, @unchecked Sendable {
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var _failingConnects: Int
        private var _failingPings: Int
        private var _connectCount = 0
        private var _uploadResumeFlags: [Bool] = []
        /// How long `disconnect()` takes, like a QUIT round trip.
        var disconnectDelay: Duration = .zero
        /// How long each download takes.
        var downloadDelay: Duration = .zero
        private var _downloadsRunning = 0
        private var _mostDownloadsAtOnce = 0
        var mostDownloadsAtOnce: Int { lock.withLock { _mostDownloadsAtOnce } }
        func downloadStarted() {
            lock.withLock {
                _downloadsRunning += 1
                _mostDownloadsAtOnce = max(_mostDownloadsAtOnce, _downloadsRunning)
            }
        }
        func downloadEnded() { lock.withLock { _downloadsRunning -= 1 } }
        /// Whether upload destinations already exist (i.e. every upload conflicts).
        let destinationsExist: Bool
        init(failingConnects: Int = 0, failingPings: Int = 0, destinationsExist: Bool = true) {
            _failingConnects = failingConnects
            _failingPings = failingPings
            self.destinationsExist = destinationsExist
        }

        func shouldFailPing() -> Bool {
            lock.withLock {
                guard _failingPings > 0 else { return false }
                _failingPings -= 1
                return true
            }
        }
        func recordConnect() { lock.withLock { _connectCount += 1 } }
        var connectCount: Int { lock.withLock { _connectCount } }
        private var _disconnectCount = 0
        func recordDisconnect() { lock.withLock { _disconnectCount += 1 } }
        var disconnectCount: Int { lock.withLock { _disconnectCount } }

        func shouldFailConnect() -> Bool {
            lock.withLock {
                guard _failingConnects > 0 else { return false }
                _failingConnects -= 1
                return true
            }
        }
        func recordUpload(resume: Bool) { lock.withLock { _uploadResumeFlags.append(resume) } }
        var uploadResumeFlags: [Bool] { lock.withLock { _uploadResumeFlags } }
    }

    let script: Script
    init(script: Script) { self.script = script }

    func connect() async throws {
        if script.shouldFailConnect() { throw RemoteClientError.connectionFailed("scripted") }
        script.recordConnect()
    }
    func ping() async throws {
        if script.shouldFailPing() { throw RemoteClientError.notConnected }
    }
    func disconnect() async {
        if script.disconnectDelay > .zero { try? await Task.sleep(for: script.disconnectDelay) }
        script.recordDisconnect()
    }
    func listDirectory(at absolutePath: String) async throws -> [FileItem] { [] }
    func download(remotePath: String, to localURL: URL, resume: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        script.downloadStarted()
        defer { script.downloadEnded() }
        if script.downloadDelay > .zero { try await Task.sleep(for: script.downloadDelay) }
    }
    func upload(from localURL: URL, remotePath: String, resume: Bool,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        script.recordUpload(resume: resume)
    }
    func keepAlive() async {}
    func createDirectory(at absolutePath: String) async throws {}
    func delete(at absolutePath: String, isDirectory: Bool) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(_ octal: Int, at absolutePath: String) async throws {}
    func setOwnership(owner: String, group: String, at absolutePath: String) async throws {}
    func remoteModifiedDate(at remotePath: String) async -> Date? { nil }
    func setModifiedDate(_ date: Date, at remotePath: String) async {}
    func fileExists(at remotePath: String) async -> Bool { script.destinationsExist }
}

@MainActor
final class TransferQueueRetryTests: XCTestCase {

    private var savedConflict: Preferences.DefaultConflict!
    private var savedConcurrency: Int!

    override func setUp() async throws {
        // The test host shares the user's real preferences domain.
        savedConflict = Preferences.shared.defaultConflict
        savedConcurrency = Preferences.shared.maxConcurrentTransfers
        Preferences.shared.defaultConflict = .ask
        Preferences.shared.maxConcurrentTransfers = 1
    }

    override func tearDown() async throws {
        Preferences.shared.defaultConflict = savedConflict
        Preferences.shared.maxConcurrentTransfers = savedConcurrency
    }

    private func makeLocalFile() throws -> URL {
        let local = FileManager.default.temporaryDirectory
            .appending(component: "teleport-queue-\(UUID().uuidString).txt")
        try Data("contents".utf8).write(to: local)
        addTeardownBlock { try? FileManager.default.removeItem(at: local) }
        return local
    }

    /// Logging in once per file dominates many-small-file transfers; a worker
    /// keeps its connection for the next task to the same server.
    func test_consecutiveTransfersToOneServer_shareASingleConnection() async throws {
        let script = ScriptedClient.Script(destinationsExist: false)
        let queue = TransferQueueViewModel(
            passwordProvider: { _ in "" },
            clientFactory: { _, _ in ScriptedClient(script: script) }
        )
        let connection = Connection(host: "example.invalid")
        let tasks = try (1...3).map { index in
            try XCTUnwrap(queue.enqueue(
                connection: connection, direction: .upload,
                localURL: try makeLocalFile(), remotePath: "/file-\(index).txt"
            ))
        }

        try await waitUntil("all completed") { tasks.allSatisfy { $0.status == .completed } }
        XCTAssertEqual(script.connectCount, 1)
    }

    /// A kept connection the server has since dropped is replaced quietly —
    /// it must not surface as a failure or use up one of the task's retries.
    func test_keptConnectionThatWentStale_isReplacedWithoutCountingAsARetry() async throws {
        let script = ScriptedClient.Script(failingPings: 1, destinationsExist: false)
        let queue = TransferQueueViewModel(
            passwordProvider: { _ in "" },
            clientFactory: { _, _ in ScriptedClient(script: script) }
        )
        let connection = Connection(host: "example.invalid")
        let first = try XCTUnwrap(queue.enqueue(
            connection: connection, direction: .upload,
            localURL: try makeLocalFile(), remotePath: "/first.txt"
        ))
        let second = try XCTUnwrap(queue.enqueue(
            connection: connection, direction: .upload,
            localURL: try makeLocalFile(), remotePath: "/second.txt"
        ))

        try await waitUntil("both completed") { first.status == .completed && second.status == .completed }
        XCTAssertEqual(script.connectCount, 2)
        XCTAssertEqual(second.retryCount, 0)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A dropped first connection must not make the retry skip the "file
    /// already exists" question, nor treat the existing remote file as this
    /// transfer's own partial upload and append to it.
    func test_uploadRetriedAfterAFailedConnect_stillAsksAboutTheConflict_andDoesNotResume() async throws {
        let script = ScriptedClient.Script(failingConnects: 1)
        let queue = TransferQueueViewModel(
            passwordProvider: { _ in "" },
            clientFactory: { _, _ in ScriptedClient(script: script) }
        )
        let local = FileManager.default.temporaryDirectory
            .appending(component: "teleport-retry-\(UUID().uuidString).txt")
        try Data("new contents".utf8).write(to: local)
        addTeardownBlock { try? FileManager.default.removeItem(at: local) }

        let task = try XCTUnwrap(queue.enqueue(
            connection: Connection(host: "example.invalid"), direction: .upload,
            localURL: local, remotePath: "/existing.txt"
        ))

        try await waitUntil("conflict prompt or a finished task") {
            queue.pendingConflict != nil || task.status.isFinal
        }
        XCTAssertNotNil(queue.pendingConflict, "The retry must still ask before overwriting")
        queue.resolveConflict(.overwrite, applyToAll: false)

        try await waitUntil("completed") { task.status.isFinal }
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(script.uploadResumeFlags, [false],
                       "Nothing was transferred yet, so there is nothing to resume")
    }

    /// Drives the "transfers finished" notice and the quit warning.
    func test_queue_reportsUnfinishedWork_thenASummaryOnceItDrains() async throws {
        let script = ScriptedClient.Script(destinationsExist: false)
        let queue = TransferQueueViewModel(
            passwordProvider: { _ in "" },
            clientFactory: { _, _ in ScriptedClient(script: script) }
        )
        var summaries: [TransferQueueViewModel.IdleSummary] = []
        queue.onIdle = { summaries.append($0) }
        XCTAssertFalse(queue.hasUnfinishedTransfers)

        let connection = Connection(host: "example.invalid")
        for index in 1...3 {
            queue.enqueue(connection: connection, direction: .upload,
                          localURL: try makeLocalFile(), remotePath: "/idle-\(index).txt")
        }
        XCTAssertTrue(queue.hasUnfinishedTransfers)

        try await waitUntil("idle summary") { !summaries.isEmpty }
        XCTAssertFalse(queue.hasUnfinishedTransfers)
        XCTAssertEqual(summaries.map(\.completed), [3])
        XCTAssertEqual(summaries.map(\.failed), [0])

        // A later batch reports only its own work.
        queue.enqueue(connection: connection, direction: .upload,
                      localURL: try makeLocalFile(), remotePath: "/idle-4.txt")
        try await waitUntil("second idle summary") { summaries.count == 2 }
        XCTAssertEqual(summaries.map(\.completed), [3, 1])
    }

    /// A real site tree (a CMS install, a build output folder) easily runs to
    /// several thousand files; the old 2,000-item cap refused them outright.
    func test_folderUpload_acceptsATreeOfSeveralThousandFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: "teleport-tree-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for dir in 0..<25 {
            let sub = root.appending(component: "dir-\(dir)")
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for file in 0..<100 {
                FileManager.default.createFile(atPath: sub.appending(component: "f\(file).txt").path, contents: Data())
            }
        }

        let script = ScriptedClient.Script(destinationsExist: false)
        let queue = TransferQueueViewModel(
            passwordProvider: { _ in "" },
            clientFactory: { _, _ in ScriptedClient(script: script) }
        )
        try await queue.enqueueFolderUpload(
            connection: Connection(host: "example.invalid"),
            folderURL: root, remoteParent: "/site"
        )

        XCTAssertEqual(queue.tasks.count, 2_500)
        try await waitUntil("all uploaded", timeout: 60) { queue.tasks.allSatisfy { $0.status == .completed } }
    }

    /// Work that must outlive a browsing tab (a drag out to Finder, a folder
    /// transfer's preparation) gets a connection of its own, always closed.
    func test_withOwnConnection_connectsRunsAndDisconnects_evenWhenTheWorkThrows() async throws {
        let script = ScriptedClient.Script(destinationsExist: false)
        let queue = TransferQueueViewModel(
            passwordProvider: { _ in "" },
            clientFactory: { _, _ in ScriptedClient(script: script) }
        )
        let connection = Connection(host: "example.invalid")

        let answer = try await queue.withOwnConnection(to: connection) { client in
            await client.fileExists(at: "/anything") ? "exists" : "missing"
        }
        XCTAssertEqual(answer, "missing")
        XCTAssertEqual(script.connectCount, 1)
        XCTAssertEqual(script.disconnectCount, 1)

        struct Boom: Error {}
        do {
            try await queue.withOwnConnection(to: connection) { _ in throw Boom() }
            XCTFail("The work's error should propagate")
        } catch is Boom {}
        XCTAssertEqual(script.disconnectCount, 2)
    }

    private func makeQueue(_ script: ScriptedClient.Script) -> TransferQueueViewModel {
        TransferQueueViewModel(
            passwordProvider: { _ in "" },
            clientFactory: { _, _ in ScriptedClient(script: script) }
        )
    }

    /// Pausing a transfer that never started leaves nothing of its own at the
    /// destination: Resume must still ask about the existing file, and must
    /// not append to it.
    func test_resumingATransferPausedBeforeItStarted_asksAboutTheConflict_andDoesNotAppend() async throws {
        let script = ScriptedClient.Script()
        let queue = makeQueue(script)
        let task = try XCTUnwrap(queue.enqueue(
            connection: Connection(host: "example.invalid"), direction: .upload,
            localURL: try makeLocalFile(), remotePath: "/existing.txt"
        ))
        queue.pause(task)                       // still queued: no worker has run yet
        XCTAssertEqual(task.status, .paused)

        queue.resume(task)
        try await waitUntil("conflict prompt or a finished task") {
            queue.pendingConflict != nil || task.status.isFinal
        }
        XCTAssertNotNil(queue.pendingConflict, "Resume must still ask before overwriting")
        queue.resolveConflict(.overwrite, applyToAll: false)

        try await waitUntil("completed") { task.status.isFinal }
        XCTAssertEqual(script.uploadResumeFlags, [false])
    }

    /// Pause pressed while the "file exists" dialog is up must pause, not
    /// skip: Skipped is final and can't be resumed.
    func test_pausingWhileTheConflictDialogIsUp_pausesTheTask() async throws {
        let script = ScriptedClient.Script()
        let queue = makeQueue(script)
        let task = try XCTUnwrap(queue.enqueue(
            connection: Connection(host: "example.invalid"), direction: .upload,
            localURL: try makeLocalFile(), remotePath: "/existing.txt"
        ))
        try await waitUntil("conflict prompt") { queue.pendingConflict != nil }

        queue.pause(task)
        try await waitUntil("settled") { task.status == .paused || task.status.isFinal }
        XCTAssertEqual(task.status, .paused)
        XCTAssertNil(queue.pendingConflict)

        queue.resume(task)
        try await waitUntil("asked again") { queue.pendingConflict != nil || task.status.isFinal }
        XCTAssertNotNil(queue.pendingConflict)
        queue.resolveConflict(.skip, applyToAll: false)
        try await waitUntil("skipped") { task.status.isFinal }
    }

    /// A transfer added while the last worker is logging out of the server
    /// must still run, not sit in the queue until something else is added.
    func test_aTransferAddedWhileTheLastWorkerIsClosingItsConnection_stillRuns() async throws {
        let script = ScriptedClient.Script(destinationsExist: false)
        script.disconnectDelay = .milliseconds(500)
        let queue = makeQueue(script)
        let connection = Connection(host: "example.invalid")
        let first = try XCTUnwrap(queue.enqueue(
            connection: connection, direction: .upload,
            localURL: try makeLocalFile(), remotePath: "/first.txt"
        ))
        try await waitUntil("first completed") { first.status == .completed }

        let second = try XCTUnwrap(queue.enqueue(
            connection: connection, direction: .upload,
            localURL: try makeLocalFile(), remotePath: "/second.txt"
        ))
        try await waitUntil("second completed", timeout: 5) { second.status == .completed }
    }

    /// "Apply to all" belongs to the batch it was chosen in. A paused task
    /// left over from that batch must not carry it into an unrelated one.
    func test_applyToAll_doesNotCarryIntoALaterBatch_whileATaskIsPaused() async throws {
        let script = ScriptedClient.Script()
        let queue = makeQueue(script)
        let connection = Connection(host: "example.invalid")
        let parked = try XCTUnwrap(queue.enqueue(
            connection: connection, direction: .upload,
            localURL: try makeLocalFile(), remotePath: "/parked.txt"
        ))
        queue.pause(parked)
        let first = try XCTUnwrap(queue.enqueue(
            connection: connection, direction: .upload,
            localURL: try makeLocalFile(), remotePath: "/a.txt"
        ))
        try await waitUntil("conflict prompt") { queue.pendingConflict != nil }
        queue.resolveConflict(.overwrite, applyToAll: true)
        try await waitUntil("first completed") { first.status == .completed }

        let later = try XCTUnwrap(queue.enqueue(
            connection: connection, direction: .upload,
            localURL: try makeLocalFile(), remotePath: "/b.txt"
        ))
        try await waitUntil("asked or finished") { queue.pendingConflict != nil || later.status.isFinal }
        XCTAssertNotNil(queue.pendingConflict, "A new batch must ask again")
        queue.resolveConflict(.skip, applyToAll: false)
        try await waitUntil("later settled") { later.status.isFinal }
    }

    /// "README" and "readme" are two files on a case-sensitive server but one
    /// on the Mac's disk. Downloading both at once interleaves them into one
    /// corrupt file; the second must wait, and then meet the first as a
    /// conflict like any other existing file.
    func test_downloadsWhoseNamesDifferOnlyInCase_doNotRunAtTheSameTime() async throws {
        Preferences.shared.maxConcurrentTransfers = 2
        let script = ScriptedClient.Script(destinationsExist: false)
        script.downloadDelay = .milliseconds(200)
        let queue = makeQueue(script)
        let dir = FileManager.default.temporaryDirectory.appending(component: "teleport-case-\(UUID().uuidString)")
        let connection = Connection(host: "example.invalid")
        let tasks = queue.enqueueBatch(connection: connection, direction: .download, items: [
            (dir.appending(component: "README"), "/README"),
            (dir.appending(component: "readme"), "/readme"),
        ])
        XCTAssertEqual(tasks.count, 2)

        try await waitUntil("both finished") { tasks.allSatisfy(\.status.isFinal) }
        XCTAssertEqual(script.mostDownloadsAtOnce, 1)
    }
}
