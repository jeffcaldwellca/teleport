import XCTest
@testable import TeleportKit

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

    // MARK: - MLSD symlinks

    /// Servers spell a symlink's type several ways. Taking one for a plain
    /// file would have a sync treat the link as a file to replace or delete.
    func test_mlsd_recognisesEverySymlinkSpelling() {
        for type in ["OS.unix=symlink", "os.unix=slink", "OS.unix=slink:/srv/releases/3", "OS.unix=slink:../shared"] {
            let item = FTPListingParser.mlsdLine("type=\(type);size=11;modify=20240115103000; current", basePath: "/var/www")
            XCTAssertEqual(item?.isSymlink, true, type)
            XCTAssertEqual(item?.name, "current", type)
        }
        let plain = FTPListingParser.mlsdLine("type=file;size=11;modify=20240115103000; a.txt", basePath: "/var/www")
        XCTAssertEqual(plain?.isSymlink, false)
    }

    // MARK: - LIST names

    /// The name is everything after the date column, exactly: a transfer of
    /// a name the parser altered asks the server for a file that isn't there.
    func test_list_keepsNamesExactly() {
        let doubleSpace = FTPListingParser.listLine("-rw-r--r-- 1 u g 5 Jan 15 2024 my  file.txt", basePath: "/")
        XCTAssertEqual(doubleSpace?.name, "my  file.txt")
        let trailing = FTPListingParser.listLine("-rw-r--r-- 1 u g 5 Jan 15 2024 notes ", basePath: "/")
        XCTAssertEqual(trailing?.name, "notes ")
        let arrow = FTPListingParser.listLine("-rw-r--r-- 1 u g 5 Jan 15 10:30 a -> b.txt", basePath: "/d")
        XCTAssertEqual(arrow?.name, "a -> b.txt")
        XCTAssertEqual(arrow?.path, "/d/a -> b.txt")
        XCTAssertNil(arrow?.symlinkTarget)
    }

    func test_list_symlink_splitsOffItsTarget() {
        let link = FTPListingParser.listLine("lrwxrwxrwx 1 u g 9 Jan 15 10:30 current -> release-3", basePath: "/srv")
        XCTAssertEqual(link?.name, "current")
        XCTAssertEqual(link?.isSymlink, true)
        XCTAssertEqual(link?.symlinkTarget, "release-3")
    }

    /// Some servers leave out the group column.
    func test_list_withoutAGroupColumn() {
        let item = FTPListingParser.listLine("-rw-r--r-- 1 owner 1234 Jan 15 2024 a b.txt", basePath: "/")
        XCTAssertEqual(item?.name, "a b.txt")
        XCTAssertEqual(item?.size, 1234)
        XCTAssertEqual(item?.owner, "owner")
    }

    /// IIS and other Windows servers answer LIST in DOS style. Without MLSD
    /// that's all there is, so not parsing it shows every folder as empty.
    func test_list_windowsStyle() {
        let dir = FTPListingParser.listLine("01-15-24  10:30AM       <DIR>          Old Projects", basePath: "/")
        XCTAssertEqual(dir?.name, "Old Projects")
        XCTAssertEqual(dir?.isDirectory, true)
        XCTAssertEqual(dir?.modifiedDate, utcDate(2024, 1, 15, 10, 30))

        let file = FTPListingParser.listLine("12-01-2023  01:05PM             1234 report.pdf", basePath: "/")
        XCTAssertEqual(file?.name, "report.pdf")
        XCTAssertEqual(file?.isDirectory, false)
        XCTAssertEqual(file?.size, 1234)
        XCTAssertEqual(file?.modifiedDate, utcDate(2023, 12, 1, 13, 5))
    }

    func test_listing_keepsTrailingSpacesInNames() async throws {
        server.listReply = { _ in "-rw-r--r-- 1 u g 5 Jan 15 2024 notes \r\n" }
        let client = try await connectedClient()
        let items = try await client.listDirectory(at: "/")
        XCTAssertEqual(items.map(\.name), ["notes "])
    }

    // MARK: - Names that aren't UTF-8

    func test_nonUTF8Name_goesBackOutAsTheSameBytes() {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])                   // "café" in Latin-1
        let name = FTPNameEncoding.decode(latin1)
        XCTAssertTrue(name.hasPrefix("caf"))
        XCTAssertEqual(FTPNameEncoding.encode(name), latin1)
    }

    func test_UTF8Names_areUnchanged_evenNextToANonUTF8One() {
        let listing = Data("-rw-r--r-- 1 u g 5 Jan 15 2024 café\r\n".utf8)
            + Data("-rw-r--r-- 1 u g 5 Jan 15 2024 caf".utf8) + Data([0xE9]) + Data("\r\n".utf8)
        let names = FTPListingParser.lines(of: listing).compactMap { FTPListingParser.listLine($0, basePath: "/")?.name }
        XCTAssertEqual(names.first, "café")
        XCTAssertEqual(FTPNameEncoding.encode(names[1]), Data([0x63, 0x61, 0x66, 0xE9]))
        XCTAssertEqual(FTPNameEncoding.encode("RETR /café"), Data("RETR /café".utf8))
    }
}
