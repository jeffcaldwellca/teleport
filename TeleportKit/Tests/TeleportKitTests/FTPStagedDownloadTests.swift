import XCTest
import TeleportKit

/// `FTPClient` downloads against a scripted in-process server: an existing
/// local file must survive a failed download (see `DownloadStaging`).
final class FTPStagedDownloadTests: XCTestCase {

    private var server: FakeFTPServer!
    private var dir: URL!

    override func setUpWithError() throws {
        server = try FakeFTPServer()
        dir = FileManager.default.temporaryDirectory
            .appending(component: "teleport-ftp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeClient() -> FTPClient {
        FTPClient(
            connection: Connection(host: "127.0.0.1", port: server.port,
                                   username: "test", connectionProtocol: .ftp),
            password: ""
        )
    }

    private func existingDestination(_ contents: String = "old contents") throws -> URL {
        let dest = dir.appending(component: "file.txt")
        try Data(contents.utf8).write(to: dest)
        return dest
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func test_download_refusedByServer_leavesExistingFileUntouched() async throws {
        let dest = try existingDestination()
        server.retr = .refuse

        let client = makeClient()
        try await client.connect()
        do {
            try await client.download(remotePath: "/file.txt", to: dest, resume: false) { _, _ in }
            XCTFail("A refused RETR should throw")
        } catch {}

        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "old contents")
        XCTAssertFalse(exists(DownloadStaging.partialURL(for: dest)),
                       "An empty partial file should not be left behind")
    }

    func test_download_interrupted_keepsExistingFileAndThePartialBytes() async throws {
        let dest = try existingDestination()
        server.reportedSize = 10
        server.retr = .send(Data("0123".utf8), finalReply: "426 connection closed; transfer aborted")

        let client = makeClient()
        try await client.connect()
        do {
            try await client.download(remotePath: "/file.txt", to: dest, resume: false) { _, _ in }
            XCTFail("An aborted transfer should throw")
        } catch {}

        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "old contents")
        XCTAssertEqual(try String(contentsOf: DownloadStaging.partialURL(for: dest), encoding: .utf8), "0123")
    }

    func test_download_success_replacesDestinationAndRemovesPartial() async throws {
        let dest = try existingDestination()
        server.reportedSize = 5
        server.retr = .send(Data("hello".utf8), finalReply: "226 done")

        let client = makeClient()
        try await client.connect()
        try await client.download(remotePath: "/file.txt", to: dest, resume: false) { _, _ in }

        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "hello")
        XCTAssertFalse(exists(DownloadStaging.partialURL(for: dest)))
    }

    func test_download_resume_continuesFromThePartialFile() async throws {
        let dest = dir.appending(component: "file.txt")
        try Data("he".utf8).write(to: DownloadStaging.partialURL(for: dest))
        server.reportedSize = 5
        server.retr = .send(Data("hello".utf8), finalReply: "226 done")

        let client = makeClient()
        try await client.connect()
        try await client.download(remotePath: "/file.txt", to: dest, resume: true) { _, _ in }

        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "hello")
        XCTAssertFalse(exists(DownloadStaging.partialURL(for: dest)))
    }

    func test_download_withoutResume_ignoresAStalePartialFile() async throws {
        let dest = dir.appending(component: "file.txt")
        try Data("XX".utf8).write(to: DownloadStaging.partialURL(for: dest))
        server.reportedSize = 5
        server.retr = .send(Data("hello".utf8), finalReply: "226 done")

        let client = makeClient()
        try await client.connect()
        try await client.download(remotePath: "/file.txt", to: dest, resume: false) { _, _ in }

        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "hello")
    }
}
