import XCTest
@testable import Teleport

final class LocalFileServiceTests: XCTestCase {

    func test_delete_movesTheItemToTheTrashInsteadOfRemovingIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "teleport-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(component: "doomed-\(UUID().uuidString).txt")
        try Data("keep me recoverable".utf8).write(to: file)

        let trashed = try XCTUnwrap(try LocalFileService.shared.delete(at: file))
        addTeardownBlock { try? FileManager.default.removeItem(at: trashed) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: trashed, encoding: .utf8), "keep me recoverable")
    }
}
