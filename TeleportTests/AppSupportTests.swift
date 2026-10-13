import XCTest
@testable import Teleport

final class AppSupportTests: XCTestCase {

    // MARK: - File list dates

    /// "2 years ago" can't tell two old files apart; the list shows the date.
    func test_fileListDate_forAnOldFile_showsTheActualDateNotAnAge() {
        var components = DateComponents()
        components.year = 2020; components.month = 3; components.day = 14; components.hour = 15
        let date = Calendar.current.date(from: components)!

        let text = FileListDate.string(for: date)

        XCTAssertTrue(text.contains("2020"), text)
        XCTAssertFalse(text.contains("ago"), text)
    }

    // MARK: - Temporary files

    /// Copies of remote files fetched for editing, previewing or dragging were
    /// never removed. Leftovers from earlier runs are swept at launch.
    func test_sweepStaleTemporaryFiles_removesOnlyTeleportsOwnWorkFolders() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(component: "teleport-sweep-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let ours = ["Edit-\(UUID().uuidString)", "Duplicate-\(UUID().uuidString)", "Drag-\(UUID().uuidString)", "QuickLook"]
        let theirs = ["Editor-settings", "SomeoneElse"]
        for name in ours + theirs {
            let dir = base.appending(component: name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appending(component: "file.txt"))
        }

        TemporaryFiles.sweepStale(in: base)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: base.path).sorted()
        XCTAssertEqual(remaining, theirs.sorted())
    }
}
