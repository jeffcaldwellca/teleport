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
}
