import XCTest
import TeleportKit
@testable import Teleport

/// Records the paths a browser pane asks the server to create or rename.
private final class PathRecordingClient: RemoteClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _created: [String] = []
    private var _renames: [(from: String, to: String)] = []
    var created: [String] { lock.withLock { _created } }
    var renames: [(from: String, to: String)] { lock.withLock { _renames } }

    func createDirectory(at absolutePath: String) async throws { lock.withLock { _created.append(absolutePath) } }
    func rename(from: String, to: String) async throws { lock.withLock { _renames.append((from, to)) } }

    func connect() async throws {}
    func disconnect() async {}
    func listDirectory(at absolutePath: String) async throws -> [FileItem] { [] }
    func download(remotePath: String, to localURL: URL, resume: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func upload(from localURL: URL, remotePath: String, resume: Bool,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func keepAlive() async {}
    func ping() async throws {}
    func delete(at absolutePath: String, isDirectory: Bool) async throws {}
    func setPermissions(_ octal: Int, at absolutePath: String) async throws {}
    func setOwnership(owner: String, group: String, at absolutePath: String) async throws {}
    func remoteModifiedDate(at remotePath: String) async -> Date? { nil }
    func setModifiedDate(_ date: Date, at remotePath: String) async {}
    func fileExists(at remotePath: String) async -> Bool { false }
}

/// A server whose listings can be held open, to catch a reload while it's in
/// flight. Counts listings and reconnects; can fail the next listing on demand.
private final class GatedListingClient: RemoteClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _listings = 0
    private var _connects = 0
    private var _gate: CheckedContinuation<Void, Never>?
    private var _holdNext = false
    private var _failNextWith: Error?
    var listings: Int { lock.withLock { _listings } }
    var connects: Int { lock.withLock { _connects } }
    var isHolding: Bool { lock.withLock { _gate != nil } }

    func holdNextListing() { lock.withLock { _holdNext = true } }
    func failNextListing(with error: Error) { lock.withLock { _failNextWith = error } }
    func release() {
        let gate: CheckedContinuation<Void, Never>? = lock.withLock { defer { _gate = nil }; return _gate }
        gate?.resume()
    }

    func listDirectory(at absolutePath: String) async throws -> [FileItem] {
        let (hold, failure): (Bool, Error?) = lock.withLock {
            _listings += 1
            defer { _holdNext = false; _failNextWith = nil }
            return (_holdNext, _failNextWith)
        }
        if let failure { throw failure }
        if hold { await withCheckedContinuation { c in lock.withLock { _gate = c } } }
        try Task.checkCancellation()
        return []
    }

    func connect() async throws { lock.withLock { _connects += 1 } }
    func disconnect() async {}
    func download(remotePath: String, to localURL: URL, resume: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func upload(from localURL: URL, remotePath: String, resume: Bool,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {}
    func keepAlive() async {}
    func ping() async throws {}
    func createDirectory(at absolutePath: String) async throws {}
    func delete(at absolutePath: String, isDirectory: Bool) async throws {}
    func rename(from: String, to: String) async throws {}
    func setPermissions(_ octal: Int, at absolutePath: String) async throws {}
    func setOwnership(owner: String, group: String, at absolutePath: String) async throws {}
    func remoteModifiedDate(at remotePath: String) async -> Date? { nil }
    func setModifiedDate(_ date: Date, at remotePath: String) async {}
    func fileExists(at remotePath: String) async -> Bool { false }
}

@MainActor
final class BrowserViewModelTests: XCTestCase {

    func test_createDirectory_atTheRoot_doesNotDoubleTheSlash() async throws {
        let client = PathRecordingClient()
        let browser = BrowserViewModel(client: client, initialPath: "/")

        try await browser.createDirectory(named: "site")

        XCTAssertEqual(client.created, ["/site"])
    }

    func test_createDirectory_inASubfolder_joinsWithOneSlash() async throws {
        let client = PathRecordingClient()
        let browser = BrowserViewModel(client: client, initialPath: "/var/www")

        try await browser.createDirectory(named: "site")

        XCTAssertEqual(client.created, ["/var/www/site"])
    }

    func test_rename_ofAnItemAtTheRoot_doesNotDoubleTheSlash() async throws {
        let client = PathRecordingClient()
        let browser = BrowserViewModel(client: client, initialPath: "/")
        let item = FileItem(name: "old.txt", path: "/old.txt", isDirectory: false)

        try await browser.rename(item: item, to: "new.txt")

        XCTAssertEqual(client.renames.map(\.to), ["/new.txt"])
    }

    // MARK: Reloads after transfers

    /// Waits (briefly) for something the browser does on its own schedule.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func test_aCancelledListing_isNotShownAsAnError_andDoesNotReconnect() async {
        let client = GatedListingClient()
        let browser = BrowserViewModel(client: client, initialPath: "/")
        client.failNextListing(with: CancellationError())

        await browser.refresh()

        XCTAssertNil(browser.loadError)
        XCTAssertEqual(client.connects, 0)
    }

    func test_aTransferLandingMidReload_doesNotCancelTheReload_andReloadsAgainAfter() async {
        let client = GatedListingClient()
        let browser = BrowserViewModel(client: client, initialPath: "/")
        browser.refreshDebounce = .milliseconds(20)

        client.holdNextListing()
        browser.scheduleRefresh()
        await waitUntil { client.isHolding }

        // Another upload finishes while that listing is still running.
        browser.scheduleRefresh()
        try? await Task.sleep(for: .milliseconds(100))
        client.release()

        await waitUntil { client.listings == 2 && !browser.isLoading }
        XCTAssertNil(browser.loadError)
    }
}
