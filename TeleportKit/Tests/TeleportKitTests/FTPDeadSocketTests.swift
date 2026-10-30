import XCTest
@testable import TeleportKit

/// `FTPClient` against a scripted in-process server that closes the control
/// connection: writes to the dead socket must fail cleanly.
final class FTPDeadSocketTests: XCTestCase {

    private var server: FakeFTPServer!

    override func setUpWithError() throws {
        server = try FakeFTPServer()
    }

    override func tearDownWithError() throws {
        server.stop()
    }

    private func makeClient() -> FTPClient {
        FTPClient(
            connection: Connection(host: "127.0.0.1", port: server.port,
                                   username: "test", connectionProtocol: .ftp),
            password: ""
        )
    }

    func test_writingToServerClosedConnection_doesNotKillTheProcess() async throws {
        server.dropControlAfterLogin = true
        let client = makeClient()
        try await client.connect()

        // The first write after the server's close provokes a reset; a second
        // write on the reset socket raises SIGPIPE unless it's suppressed.
        _ = await client.fileExists(at: "/a")
        try await Task.sleep(for: .milliseconds(200))
        _ = await client.fileExists(at: "/a")
    }

    func test_failedKeepAlive_dropsTheSocketSoTheNextOperationReportsNotConnected() async throws {
        server.dropControlAfterLogin = true
        let client = makeClient()
        try await client.connect()

        await client.keepAlive()

        do {
            _ = try await client.listDirectory(at: "/")
            XCTFail("Listing on a dropped connection should throw")
        } catch RemoteClientError.notConnected {
            // expected: callers treat this as "reconnect"
        }
    }

    func test_aListingCancelledAfterItStarted_dropsTheSessionInsteadOfLeavingItsReplyUnread() async throws {
        server.mlsdListing = "type=file;size=1; a.txt\r\n"
        server.listingDelay = 3
        let client = makeClient()
        try await client.connect()

        let listing = Task { try await client.listDirectory(at: "/") }
        try await Task.sleep(for: .milliseconds(300))
        listing.cancel()
        _ = try? await listing.value

        // The listing's "226" is still on its way. Reading it as the reply to
        // the next command would put every later reply one command behind;
        // the session must be dropped so the caller reconnects instead.
        server.listingDelay = 0
        do {
            _ = try await client.listDirectory(at: "/")
            XCTFail("The session should have been dropped")
        } catch RemoteClientError.notConnected {
            // expected
        }
    }

    func test_pingAnsweredWithAnythingButSuccess_failsAndDropsTheSession() async throws {
        server.noopReply = "421 Timeout"
        let client = makeClient()
        try await client.connect()

        do {
            try await client.ping()
            XCTFail("A 421 must not count as a live connection")
        } catch {}
        do {
            _ = try await client.listDirectory(at: "/")
            XCTFail("The session should have been dropped")
        } catch RemoteClientError.notConnected {}
    }

    func test_timestamps_areGregorianUTC_whateverTheUsersCalendar() {
        let fmt = FTPClient.timestampFormatter()
        let date = fmt.date(from: "20240305120000")
        XCTAssertEqual(date?.timeIntervalSince1970, 1_709_640_000)
        XCTAssertEqual(fmt.calendar.identifier, .gregorian)
    }

    func test_fileExists_findsFoldersToo() async throws {
        server.directories = ["/site"]
        let client = makeClient()
        try await client.connect()

        let folder = await client.fileExists(at: "/site")
        let missing = await client.fileExists(at: "/nothing")
        XCTAssertTrue(folder)
        XCTAssertFalse(missing)
    }
}
