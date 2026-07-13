import XCTest
import TeleportKit

final class RemotePathTests: XCTestCase {

    // MARK: - validateCommand

    func test_validateCommand_acceptsNormalCommands() throws {
        XCTAssertNoThrow(try RemotePath.validateCommand("USER alice"))
        XCTAssertNoThrow(try RemotePath.validateCommand("PASS hunter2"))
        XCTAssertNoThrow(try RemotePath.validateCommand("RETR /var/log/messages"))
        XCTAssertNoThrow(try RemotePath.validateCommand("MKD /home/foo bar"))   // space ok
    }

    func test_validateCommand_rejectsCarriageReturn() {
        XCTAssertThrowsError(try RemotePath.validateCommand("RETR foo\r\nDELE bar")) { err in
            XCTAssertTrue(err is RemotePathError)
        }
    }

    func test_validateCommand_rejectsLineFeed() {
        XCTAssertThrowsError(try RemotePath.validateCommand("USER alice\n")) { err in
            XCTAssertTrue(err is RemotePathError)
        }
    }

    func test_validateCommand_rejectsNUL() {
        XCTAssertThrowsError(try RemotePath.validateCommand("RETR foo\u{00}.txt")) { err in
            XCTAssertTrue(err is RemotePathError)
        }
    }

    // MARK: - sanitizedFilename

    func test_sanitizedFilename_passesNormalNames() {
        XCTAssertEqual(RemotePath.sanitizedFilename("hello.txt"), "hello.txt")
        XCTAssertEqual(RemotePath.sanitizedFilename("My Document"), "My Document")
        XCTAssertEqual(RemotePath.sanitizedFilename("café.png"), "café.png")
        XCTAssertEqual(RemotePath.sanitizedFilename(" leading-space.txt"), " leading-space.txt")
    }

    func test_sanitizedFilename_rejectsEmpty() {
        XCTAssertNil(RemotePath.sanitizedFilename(""))
    }

    func test_sanitizedFilename_rejectsDotEntries() {
        XCTAssertNil(RemotePath.sanitizedFilename("."))
        XCTAssertNil(RemotePath.sanitizedFilename(".."))
    }

    func test_sanitizedFilename_rejectsPathSeparators() {
        XCTAssertNil(RemotePath.sanitizedFilename("foo/bar"))
        XCTAssertNil(RemotePath.sanitizedFilename("..\\baz"))
        XCTAssertNil(RemotePath.sanitizedFilename("../etc/passwd"))
    }

    func test_sanitizedFilename_rejectsControlCharacters() {
        XCTAssertNil(RemotePath.sanitizedFilename("foo\nbar"))
        XCTAssertNil(RemotePath.sanitizedFilename("foo\rbar"))
        XCTAssertNil(RemotePath.sanitizedFilename("foo\u{07}bar"))    // BEL
        XCTAssertNil(RemotePath.sanitizedFilename("foo\u{7F}bar"))    // DEL
    }

    func test_sanitizedFilename_rejectsRTLOverride() {
        // U+202E is the RIGHT-TO-LEFT OVERRIDE — used to disguise file extensions.
        XCTAssertNil(RemotePath.sanitizedFilename("invoice\u{202E}gpj.exe"))
    }

    func test_sanitizedFilename_rejectsBidiIsolates() {
        XCTAssertNil(RemotePath.sanitizedFilename("foo\u{2068}bar"))   // FSI
        XCTAssertNil(RemotePath.sanitizedFilename("foo\u{2069}bar"))   // PDI
    }

    // MARK: - isContained

    func test_isContained_acceptsDescendant() {
        let base = URL(fileURLWithPath: "/Users/test/Desktop")
        let dest = URL(fileURLWithPath: "/Users/test/Desktop/file.txt")
        XCTAssertTrue(RemotePath.isContained(dest, in: base))
    }

    func test_isContained_acceptsBaseItself() {
        let base = URL(fileURLWithPath: "/Users/test/Desktop")
        XCTAssertTrue(RemotePath.isContained(base, in: base))
    }

    func test_isContained_rejectsSibling() {
        let base = URL(fileURLWithPath: "/Users/test/Desktop")
        let dest = URL(fileURLWithPath: "/Users/test/Documents/file.txt")
        XCTAssertFalse(RemotePath.isContained(dest, in: base))
    }

    func test_isContained_rejectsParent() {
        let base = URL(fileURLWithPath: "/Users/test/Desktop")
        let dest = URL(fileURLWithPath: "/Users/test")
        XCTAssertFalse(RemotePath.isContained(dest, in: base))
    }

    func test_isContained_rejectsTraversal() {
        let base = URL(fileURLWithPath: "/Users/test/Desktop")
        // Even if the URL resolved to a sibling via .., we must catch it.
        let dest = base.appending(component: "..").appending(component: "Documents")
        XCTAssertFalse(RemotePath.isContained(dest, in: base))
    }
}
