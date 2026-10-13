import XCTest
import TeleportKit

final class DisplayFormattingTests: XCTestCase {

    // MARK: - Permissions

    func test_displayPermissions_normalisesEveryServerFormat() {
        func item(_ permissions: String?) -> FileItem {
            FileItem(name: "f", path: "/f", isDirectory: false, permissions: permissions)
        }
        XCTAssertEqual(item("-rw-r--r--").displayPermissions, "rw-r--r--")   // LIST
        XCTAssertEqual(item("drwxr-xr-x").displayPermissions, "rwxr-xr-x")   // LIST, directory
        XCTAssertEqual(item("755").displayPermissions, "rwxr-xr-x")          // MLSD unix.mode
        XCTAssertEqual(item("0644").displayPermissions, "rw-r--r--")         // MLSD, leading zero
        XCTAssertEqual(item("100644").displayPermissions, "rw-r--r--")       // SFTP, with file-type bits
        XCTAssertEqual(item("40755").displayPermissions, "rwxr-xr-x")        // SFTP directory
        XCTAssertNil(item(nil).displayPermissions)
        XCTAssertNil(item("garbage").displayPermissions)
    }

    // MARK: - SSH fingerprints

    /// `ssh-keygen -lf` and OpenSSH's own prompts print SHA256 fingerprints as
    /// unpadded base64; showing hex makes them impossible to compare by eye.
    func test_openSSHFingerprint_isUnpaddedBase64OfTheStoredHex() {
        let zeros = "SHA256:" + String(repeating: "00", count: 32)
        XCTAssertEqual(SSHKeyFingerprint.openSSH(zeros), "SHA256:" + String(repeating: "A", count: 43))

        let mixed = "SHA256:" + (0..<32).map { String(format: "%02x", $0) }.joined()
        let expected = "SHA256:" + Data(0..<32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(SSHKeyFingerprint.openSSH(mixed), expected)
    }

    func test_openSSHFingerprint_passesThroughAnythingItCannotParse() {
        XCTAssertEqual(SSHKeyFingerprint.openSSH("MD5:aa:bb"), "MD5:aa:bb")
        XCTAssertEqual(SSHKeyFingerprint.openSSH("SHA256:xyz"), "SHA256:xyz")
    }
}
