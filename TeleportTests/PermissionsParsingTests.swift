import XCTest
@testable import Teleport

final class PermissionsParsingTests: XCTestCase {

    func test_plainModes() {
        XCTAssertEqual(PermissionsEditorSheet.parsePermissions("drwxr-xr-x"), 0o755)
        XCTAssertEqual(PermissionsEditorSheet.parsePermissions("-rw-r--r--"), 0o644)
        XCTAssertEqual(PermissionsEditorSheet.parsePermissions("0644"), 0o644)
    }

    /// Applying the sheet unchanged must not strip these bits.
    func test_specialBits_areKept() {
        XCTAssertEqual(PermissionsEditorSheet.parsePermissions("drwxrwxrwt"), 0o1777)
        XCTAssertEqual(PermissionsEditorSheet.parsePermissions("-rwsr-xr-x"), 0o4755)
        XCTAssertEqual(PermissionsEditorSheet.parsePermissions("drwxr-sr-x"), 0o2755)
    }

    /// Uppercase means the special bit without execute; it must not grant execute.
    func test_uppercaseSpecialBits_doNotAddExecute() {
        XCTAssertEqual(PermissionsEditorSheet.parsePermissions("-rwSr--r--"), 0o4644)
        XCTAssertEqual(PermissionsEditorSheet.parsePermissions("drwxr-xr-T"), 0o1754)
    }
}
