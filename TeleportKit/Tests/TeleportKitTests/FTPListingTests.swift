import XCTest
import TeleportKit

/// Directory listings against a scripted server without MLSD, plus the pure
/// `LIST` date parser.
final class FTPListingTests: XCTestCase {

    private var server: FakeFTPServer!

    override func setUpWithError() throws { server = try FakeFTPServer() }
    override func tearDownWithError() throws { server.stop() }

    private func connectedClient() async throws -> FTPClient {
        let client = FTPClient(
            connection: Connection(host: "127.0.0.1", port: server.port,
                                   username: "test", connectionProtocol: .ftp),
            password: ""
        )
        try await client.connect()
        return client
    }

    private static let visibleOnly = "-rw-r--r-- 1 u g 5 Jan 15 2024 index.html\r\n"
    private static let withHidden =
        "drwxr-xr-x 2 u g 4096 Jan 15 2024 .\r\n" +
        "drwxr-xr-x 2 u g 4096 Jan 15 2024 ..\r\n" +
        "-rw-r--r-- 1 u g 12 Jan 15 2024 .htaccess\r\n" + visibleOnly

    private func count(_ verb: String) -> Int {
        server.commands.filter { $0.hasPrefix(verb) }.count
    }

    // MARK: - Hidden files

    func test_listFallback_asksForHiddenFiles() async throws {
        server.listReply = { $0 == "-a /site" ? Self.withHidden : Self.visibleOnly }
        let client = try await connectedClient()

        let names = try await client.listDirectory(at: "/site").map(\.name).sorted()

        XCTAssertEqual(names, [".htaccess", "index.html"])
    }

    func test_listFallback_serverThatRejectsDashA_stillLists() async throws {
        server.listReply = { $0 == "/site" ? Self.visibleOnly : nil }
        let client = try await connectedClient()

        let names = try await client.listDirectory(at: "/site").map(\.name)

        XCTAssertEqual(names, ["index.html"])
    }

    // MARK: - Capability caching

    func test_unsupportedMLSD_isProbedOncePerSession() async throws {
        server.listReply = { _ in Self.withHidden }
        let client = try await connectedClient()

        _ = try await client.listDirectory(at: "/site")
        _ = try await client.listDirectory(at: "/site")

        XCTAssertEqual(count("MLSD"), 1)
    }

    func test_unsupportedEPSV_isProbedOncePerSession() async throws {
        server.supportsEPSV = false
        server.listReply = { _ in Self.withHidden }
        let client = try await connectedClient()

        _ = try await client.listDirectory(at: "/site")
        _ = try await client.listDirectory(at: "/site")

        XCTAssertEqual(count("EPSV"), 1)
    }

    // MARK: - LIST dates

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// `ls -l` prints a time instead of a year for recent files. In early
    /// January, "Dec 28 23:10" is last month — not eleven months from now.
    func test_listDate_recentEntryFromLastYear_isNotPlacedInTheFuture() {
        let parsed = FTPListingParser.listDate("Dec", "28", "23:10", now: utcDate(2026, 1, 3))
        XCTAssertEqual(parsed, utcDate(2025, 12, 28, 23, 10))
    }

    func test_listDate_recentEntryFromThisYear_keepsTheCurrentYear() {
        let parsed = FTPListingParser.listDate("Jan", "2", "10:00", now: utcDate(2026, 1, 3))
        XCTAssertEqual(parsed, utcDate(2026, 1, 2, 10, 0))
    }
}
