import XCTest
import TeleportKit

final class SSHKeyFingerprintTests: XCTestCase {

    func test_display_groupsHexInPairs() {
        let raw = "SHA256:a1b2c3d4e5f60708090a"
        let displayed = SSHKeyFingerprint.display(raw)
        XCTAssertEqual(displayed, "SHA256:a1:b2:c3:d4:e5:f6:07:08:09:0a")
    }

    func test_display_handlesEmptyHex() {
        XCTAssertEqual(SSHKeyFingerprint.display("SHA256:"), "SHA256:")
    }

    func test_display_passesThroughUnknownPrefix() {
        XCTAssertEqual(SSHKeyFingerprint.display("MD5:01020304"), "MD5:01020304")
    }

    func test_display_handlesOddLengthGracefully() {
        // Should not crash; the trailing single digit lands in its own group.
        let result = SSHKeyFingerprint.display("SHA256:abcde")
        XCTAssertTrue(result.hasPrefix("SHA256:"))
    }
}
