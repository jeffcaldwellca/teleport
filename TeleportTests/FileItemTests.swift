import XCTest
@testable import Teleport

final class FileItemTests: XCTestCase {

    func test_id_isPathDerived_soSelectionSurvivesRefresh() {
        // Same path → same id, even when the FileItem instance is rebuilt
        // (e.g. after a directory refresh that produces fresh structs).
        let a = FileItem(name: "report.pdf", path: "/home/me/report.pdf", isDirectory: false)
        let b = FileItem(name: "report.pdf", path: "/home/me/report.pdf", isDirectory: false,
                         size: 1024, modifiedDate: Date())
        XCTAssertEqual(a.id, b.id)
    }

    func test_id_distinguishesDifferentPaths() {
        let a = FileItem(name: "x.txt", path: "/a/x.txt", isDirectory: false)
        let b = FileItem(name: "x.txt", path: "/b/x.txt", isDirectory: false)
        XCTAssertNotEqual(a.id, b.id)
    }
}

final class ConnectionEqualityTests: XCTestCase {

    func test_equality_isFieldBased() {
        let a = Connection(name: "Prod", host: "example.com", port: 22,
                           username: "alice", connectionProtocol: .sftp)

        // Identical copies compare equal.
        let copy = a
        XCTAssertEqual(a, copy)
        XCTAssertEqual(a.hashValue, copy.hashValue)

        // Any field change makes them unequal. Equality must stay field-based:
        // the connection editor edits a `@State Connection`, and SwiftUI only
        // re-renders (so the Save/Add button enables, fields update, …) when the
        // value actually compares unequal. Identity for store lookups and list
        // selection is handled explicitly by `id` (UUID), not by `==`.
        var edited = a
        edited.name = "Production"
        XCTAssertNotEqual(a, edited)
    }
}

final class FTPListingParserTests: XCTestCase {

    // MARK: LIST (ls -l) parsing

    func test_listLine_parsesUnixDirectory() {
        let item = FTPListingParser.listLine(
            "drwxr-xr-x  2 alice staff  4096 Jan 15 10:30 Documents", basePath: "/home")
        XCTAssertEqual(item?.name, "Documents")
        XCTAssertEqual(item?.path, "/home/Documents")
        XCTAssertEqual(item?.isDirectory, true)
        XCTAssertEqual(item?.owner, "alice")
        XCTAssertEqual(item?.group, "staff")
    }

    func test_listLine_parsesFileWithSpacesInName() {
        let item = FTPListingParser.listLine(
            "-rw-r--r--  1 alice staff  1024 Jan 15 10:30 My Report.txt", basePath: "/x")
        XCTAssertEqual(item?.name, "My Report.txt")
        XCTAssertEqual(item?.isDirectory, false)
        XCTAssertEqual(item?.size, 1024)
    }

    func test_listLine_marksSymlink() {
        let item = FTPListingParser.listLine(
            "lrwxr-xr-x 1 a b 7 Jan 1 00:00 shortcut -> target", basePath: "/")
        XCTAssertEqual(item?.name, "shortcut")
        XCTAssertEqual(item?.isSymlink, true)
    }

    func test_listLine_rejectsTraversalName() {
        XCTAssertNil(FTPListingParser.listLine(
            "drwxr-xr-x 2 a b 4096 Jan 1 00:00 ..", basePath: "/"))
    }

    func test_listLine_rejectsMalformedLine() {
        XCTAssertNil(FTPListingParser.listLine("not a listing", basePath: "/"))
    }

    func test_listDate_isInterpretedAsUTC() throws {
        let date = try XCTUnwrap(FTPListingParser.listDate("Jan", "15", "10:30"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.month, .day, .hour, .minute], from: date)
        XCTAssertEqual(c.month, 1)
        XCTAssertEqual(c.day, 15)
        XCTAssertEqual(c.hour, 10)
        XCTAssertEqual(c.minute, 30)
    }

    // MARK: MLSD parsing

    func test_mlsdLine_parsesFile() {
        let item = FTPListingParser.mlsdLine(
            "type=file;size=2048;modify=20240115103000; report.txt", basePath: "/docs")
        XCTAssertEqual(item?.name, "report.txt")
        XCTAssertEqual(item?.path, "/docs/report.txt")
        XCTAssertEqual(item?.isDirectory, false)
        XCTAssertEqual(item?.size, 2048)
        XCTAssertNotNil(item?.modifiedDate)
    }

    func test_mlsdLine_parsesDirectory() {
        let item = FTPListingParser.mlsdLine(
            "type=dir;modify=20240115103000; folder", basePath: "/")
        XCTAssertEqual(item?.isDirectory, true)
        XCTAssertEqual(item?.name, "folder")
    }

    func test_mlsdDate_isUTC() throws {
        let date = try XCTUnwrap(FTPListingParser.mlsdDate("20240115103000"))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual(c.year, 2024)
        XCTAssertEqual(c.month, 1)
        XCTAssertEqual(c.day, 15)
        XCTAssertEqual(c.hour, 10)
        XCTAssertEqual(c.minute, 30)
        XCTAssertEqual(c.second, 0)
    }

    func test_mlsdLine_rejectsDotEntries() {
        // "." / ".." are filtered as unsafe filenames.
        XCTAssertNil(FTPListingParser.mlsdLine("type=cdir;modify=20240101000000; .", basePath: "/"))
    }
}
