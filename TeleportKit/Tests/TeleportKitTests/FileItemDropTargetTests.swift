import XCTest
import TeleportKit

/// Resolving the row under a drag to the folder a drop should land in.
final class FileItemDropTargetTests: XCTestCase {

    private func item(_ name: String, directory: Bool, symlink: Bool = false) -> FileItem {
        FileItem(name: name, path: "/x/\(name)", isDirectory: directory, isSymlink: symlink)
    }

    func test_directoryIsDropTargetFolder() {
        XCTAssertTrue(item("docs", directory: true).isDropTargetFolder)
    }

    func test_fileIsNotDropTargetFolder() {
        XCTAssertFalse(item("a.txt", directory: false).isDropTargetFolder)
    }

    func test_symlinkedDirectoryIsNotDropTargetFolder() {
        XCTAssertFalse(item("link", directory: true, symlink: true).isDropTargetFolder)
    }

    func test_dropFolder_returnsFolderAtRow() {
        let items = [item("a.txt", directory: false), item("docs", directory: true)]
        XCTAssertEqual(FileItem.dropFolder(atRow: 1, in: items)?.name, "docs")
    }

    func test_dropFolder_isNilForFileRow() {
        let items = [item("a.txt", directory: false), item("docs", directory: true)]
        XCTAssertNil(FileItem.dropFolder(atRow: 0, in: items))
    }

    func test_dropFolder_isNilOutsideRows() {
        let items = [item("docs", directory: true)]
        XCTAssertNil(FileItem.dropFolder(atRow: -1, in: items))
        XCTAssertNil(FileItem.dropFolder(atRow: 1, in: items))
    }
}
