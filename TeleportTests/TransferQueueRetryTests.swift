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
        private var _uploadResumeFlags: [Bool] = []
        init(failingConnects: Int) { _failingConnects = failingConnects }

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
    }
    func disconnect() async {}
    func listDirectory(at absolutePath: String) async throws -> [FileItem] { [] }
    func download(remotePath: String, to localURL: URL, resume: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
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
    /// Every destination already exists, so every upload is a conflict.
    func fileExists(at remotePath: String) async -> Bool { true }
}

@MainActor
final class TransferQueueRetryTests: XCTestCase {

    private var savedConflict: Preferences.DefaultConflict!

    override func setUp() async throws {
        // The test host shares the user's real preferences domain.
        savedConflict = Preferences.shared.defaultConflict
        Preferences.shared.defaultConflict = .ask
    }

    override func tearDown() async throws {
        Preferences.shared.defaultConflict = savedConflict
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
}
