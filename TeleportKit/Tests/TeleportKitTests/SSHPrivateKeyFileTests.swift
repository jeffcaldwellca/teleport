import XCTest
import TeleportKit

/// Key files generated on the fly by the system's `ssh-keygen`, so the
/// formats under test are exactly what users have on disk.
final class SSHPrivateKeyFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(component: "teleport-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Returns (private key text, "type base64" from the .pub file).
    private func generate(_ type: String, bits: Int? = nil, passphrase: String = "", cipher: String? = nil) throws -> (key: String, pub: String) {
        let path = dir.appending(component: "key-\(UUID().uuidString)").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", type] + (bits.map { ["-b", String($0)] } ?? [])
            + (cipher.map { ["-Z", $0] } ?? []) + ["-N", passphrase, "-C", "test", "-f", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "ssh-keygen failed")
        let key = try String(contentsOfFile: path, encoding: .utf8)
        let pub = try String(contentsOfFile: path + ".pub", encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")
        return (key, pub)
    }

    private func publicKey(_ key: String, passphrase: String? = nil) throws -> String {
        try SSHPrivateKeyFile.openSSHPublicKey(of: key, passphrase: passphrase)
    }

    // MARK: - ed25519

    func test_ed25519_unencrypted_parses() throws {
        let (key, pub) = try generate("ed25519")
        XCTAssertFalse(SSHPrivateKeyFile.isEncrypted(key))
        XCTAssertEqual(try publicKey(key), pub)
    }

    func test_ed25519_encrypted_withPassphrase_parses() throws {
        let (key, pub) = try generate("ed25519", passphrase: "correct horse")
        XCTAssertTrue(SSHPrivateKeyFile.isEncrypted(key))
        XCTAssertEqual(try publicKey(key, passphrase: "correct horse"), pub)
    }

    func test_encrypted_withoutPassphrase_throwsPassphraseRequired() throws {
        let (key, _) = try generate("ed25519", passphrase: "correct horse")
        XCTAssertThrowsError(try publicKey(key)) {
            XCTAssertEqual($0 as? SSHPrivateKeyFile.Failure, .passphraseRequired)
        }
    }

    func test_encrypted_wrongPassphrase_throwsWrongPassphrase() throws {
        let (key, _) = try generate("ed25519", passphrase: "correct horse")
        XCTAssertThrowsError(try publicKey(key, passphrase: "battery staple")) {
            XCTAssertEqual($0 as? SSHPrivateKeyFile.Failure, .wrongPassphrase)
        }
    }

    // MARK: - RSA

    func test_rsa_unencrypted_parses() throws {
        let (key, _) = try generate("rsa", bits: 2048)
        XCTAssertTrue(SSHPrivateKeyFile.isRSA(key))
        XCTAssertTrue(try publicKey(key).hasPrefix("ssh-rsa "))
    }

    func test_rsa_encrypted_wrongPassphrase_throwsWrongPassphrase() throws {
        let (key, _) = try generate("rsa", bits: 2048, passphrase: "correct horse")
        XCTAssertThrowsError(try publicKey(key, passphrase: "nope")) {
            XCTAssertEqual($0 as? SSHPrivateKeyFile.Failure, .wrongPassphrase)
        }
        XCTAssertTrue(try publicKey(key, passphrase: "correct horse").hasPrefix("ssh-rsa "))
    }

    // MARK: - ECDSA

    func test_ecdsa_p256_p384_p521_unencrypted_parse() throws {
        for bits in [256, 384, 521] {
            let (key, pub) = try generate("ecdsa", bits: bits)
            XCTAssertFalse(SSHPrivateKeyFile.isRSA(key))
            XCTAssertEqual(try publicKey(key), pub, "P-\(bits)")
        }
    }

    func test_ecdsa_encrypted_throwsUnsupportedNamingSshAdd() throws {
        let (key, _) = try generate("ecdsa", bits: 256, passphrase: "correct horse")
        XCTAssertThrowsError(try publicKey(key, passphrase: "correct horse")) { error in
            guard case .unsupported(let message)? = error as? SSHPrivateKeyFile.Failure else {
                return XCTFail("Expected .unsupported, got \(error)")
            }
            XCTAssertTrue(message.contains("ssh-add"), message)
        }
    }

    // MARK: - Ciphers

    /// Only aes128-ctr and aes256-ctr can be decrypted. For anything else no
    /// passphrase will ever work, so asking for one (and then calling it
    /// wrong) would send the user round in circles.
    func test_encryptedWithACipherThatCannotBeDecrypted_saysSo_withoutBlamingThePassphrase() throws {
        let (key, _) = try generate("ed25519", passphrase: "correct horse", cipher: "aes256-cbc")
        XCTAssertTrue(SSHPrivateKeyFile.isEncrypted(key))
        for passphrase in [nil, "correct horse"] {
            XCTAssertThrowsError(try publicKey(key, passphrase: passphrase)) { error in
                guard case .unsupported(let message)? = error as? SSHPrivateKeyFile.Failure else {
                    return XCTFail("Expected .unsupported, got \(error)")
                }
                XCTAssertTrue(message.contains("aes256-cbc"), message)
            }
        }
    }

    func test_canUnlock_isFalseOnlyForAWrongPassphrase() throws {
        let (encrypted, _) = try generate("ed25519", passphrase: "correct horse")
        XCTAssertTrue(SSHPrivateKeyFile.canUnlock(encrypted, passphrase: "correct horse"))
        XCTAssertFalse(SSHPrivateKeyFile.canUnlock(encrypted, passphrase: "battery staple"))
        // Not a passphrase problem, so not for the passphrase sheet to reject.
        XCTAssertTrue(SSHPrivateKeyFile.canUnlock("not a key", passphrase: "anything"))
    }

    // MARK: - Untidy input

    func test_keyWithCRLFAndTrailingBlankLines_parses() throws {
        let (key, pub) = try generate("ed25519")
        let untidy = key.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n"
        XCTAssertEqual(try publicKey(untidy), pub)
    }

    func test_notAKey_throwsUnsupported() {
        XCTAssertThrowsError(try publicKey("ssh-ed25519 AAAA this is a public key")) { error in
            guard case .unsupported? = error as? SSHPrivateKeyFile.Failure else {
                return XCTFail("Expected .unsupported, got \(error)")
            }
        }
    }
}
