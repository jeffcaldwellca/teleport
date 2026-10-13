import Foundation
import CryptoKit
import Citadel
import NIOCore
import NIOSSH

/// Turns the text of an SSH private-key file into a key that can be offered
/// to a server.
///
/// Supported: OpenSSH-format ed25519 and RSA keys (with or without a
/// passphrase), and unencrypted ECDSA P-256/384/521 keys in OpenSSH or PEM
/// form. Encrypted ECDSA files are not — Citadel only decrypts ed25519 and
/// RSA — and are pointed at ssh-agent instead.
public enum SSHPrivateKeyFile {

    public enum Failure: LocalizedError, Equatable {
        /// The file is encrypted and no passphrase was supplied.
        case passphraseRequired
        /// The file is encrypted and the supplied passphrase doesn't open it.
        case wrongPassphrase
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .passphraseRequired:     return "This SSH key is protected by a passphrase."
            case .wrongPassphrase:        return "That passphrase doesn't unlock this SSH key."
            case .unsupported(let why):   return why
            }
        }
    }

    // MARK: - Inspection

    /// True when the key needs a passphrase before it can be used.
    public static func isEncrypted(_ keyText: String) -> Bool {
        let text = normalise(keyText)
        if let container = OpenSSHContainer(text) { return container.cipher != "none" }
        return text.contains("ENCRYPTED")   // legacy PEM: "Proc-Type: 4,ENCRYPTED" / "BEGIN ENCRYPTED PRIVATE KEY"
    }

    /// True for an RSA key. Worth knowing because RSA keys can only sign
    /// with SHA-1 here, which current OpenSSH servers reject.
    public static func isRSA(_ keyText: String) -> Bool {
        let text = normalise(keyText)
        if let container = OpenSSHContainer(text) { return container.keyType == "ssh-rsa" }
        return text.contains("BEGIN RSA PRIVATE KEY")
    }

    /// The matching public key as it appears in a `.pub` file or
    /// `authorized_keys`: "<type> <base64>".
    public static func openSSHPublicKey(of keyText: String, passphrase: String?) throws -> String {
        String(openSSHPublicKey: try privateKey(from: keyText, passphrase: passphrase).publicKey)
    }

    // MARK: - Parsing

    static func privateKey(from keyText: String, passphrase: String?) throws -> NIOSSHPrivateKey {
        let text = normalise(keyText)
        guard let container = OpenSSHContainer(text) else {
            return try pemKey(from: text)
        }
        let encrypted = container.cipher != "none"
        let decryptionKey = passphrase.map { Data($0.utf8) }

        switch container.keyType {
        case "ssh-ed25519":
            if encrypted && passphrase == nil { throw Failure.passphraseRequired }
            do {
                return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(
                    sshEd25519: text, decryptionKey: encrypted ? decryptionKey : nil
                ))
            } catch {
                throw encrypted ? Failure.wrongPassphrase : Failure.unsupported("This ed25519 key file is damaged or incomplete.")
            }

        case "ssh-rsa":
            if encrypted && passphrase == nil { throw Failure.passphraseRequired }
            do {
                return NIOSSHPrivateKey(custom: try Insecure.RSA.PrivateKey(
                    sshRsa: text, decryptionKey: encrypted ? decryptionKey : nil
                ))
            } catch {
                throw encrypted ? Failure.wrongPassphrase : Failure.unsupported("This RSA key file is damaged or incomplete.")
            }

        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard !encrypted else {
                throw Failure.unsupported(
                    "Passphrase-protected ECDSA key files can't be read directly. Add the key to ssh-agent " +
                    "(`ssh-add <key file>`) and turn on \u{201C}Use ssh-agent\u{201D} for this connection."
                )
            }
            return try ecdsaKey(type: container.keyType, privateSection: container.privateSection)

        default:
            throw Failure.unsupported(
                "\(container.keyType) keys aren't supported. Supported key types: ed25519, ECDSA and RSA."
            )
        }
    }

    /// Editors and copy-paste leave CRLF line endings and stray blank lines.
    private static func normalise(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: ECDSA

    /// Unencrypted private section of an `openssh-key-v1` file:
    /// `uint32 check, uint32 check, string keytype, string curve, string Q, mpint d, string comment`.
    private static func ecdsaKey(type: String, privateSection: ByteBuffer) throws -> NIOSSHPrivateKey {
        var section = privateSection
        let damaged = Failure.unsupported("This ECDSA key file is damaged or incomplete.")
        guard let check1 = section.readInteger(as: UInt32.self),
              let check2 = section.readInteger(as: UInt32.self), check1 == check2,
              section.readSSHString() != nil,          // key type
              section.readSSHString() != nil,          // curve name
              section.readSSHString() != nil,          // public point
              let scalar = section.readSSHString() else { throw damaged }

        // The scalar is an mpint: possibly a leading zero byte, possibly
        // shorter than the field. CryptoKit wants exactly the field size.
        func raw(_ size: Int) throws -> Data {
            let bytes = Array(scalar.readableBytesView.drop(while: { $0 == 0 }))
            guard bytes.count <= size else { throw damaged }
            return Data(repeating: 0, count: size - bytes.count) + bytes
        }
        do {
            switch type {
            case "ecdsa-sha2-nistp256":
                return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: try raw(32)))
            case "ecdsa-sha2-nistp384":
                return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: try raw(48)))
            default:
                return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: try raw(66)))
            }
        } catch {
            throw damaged
        }
    }

    // MARK: PEM

    private static func pemKey(from text: String) throws -> NIOSSHPrivateKey {
        guard text.contains("PRIVATE KEY-----") else {
            throw Failure.unsupported("This file isn't an SSH private key. Choose the private key, not the .pub file.")
        }
        if text.contains("ENCRYPTED") || text.contains("BEGIN RSA PRIVATE KEY") {
            throw Failure.unsupported(
                "This key is in the older PEM format, which isn't supported here. Convert it to the OpenSSH " +
                "format with `ssh-keygen -p -f <key file>`, or add it to ssh-agent."
            )
        }
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: text) { return NIOSSHPrivateKey(p256Key: key) }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: text) { return NIOSSHPrivateKey(p384Key: key) }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: text) { return NIOSSHPrivateKey(p521Key: key) }
        throw Failure.unsupported("Unsupported key file. Supported: OpenSSH-format ed25519, ECDSA and RSA keys.")
    }
}

// MARK: - openssh-key-v1 container

/// The unencrypted header of an OpenSSH private-key file — enough to tell
/// what kind of key it holds and whether it is encrypted.
private struct OpenSSHContainer {
    let cipher: String
    let keyType: String
    let privateSection: ByteBuffer

    init?(_ text: String) {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"
        guard let start = text.range(of: begin), let stop = text.range(of: end),
              start.upperBound <= stop.lowerBound else { return nil }
        let base64 = text[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(base64)) else { return nil }

        var buffer = ByteBuffer(data: data)
        let magic = Array("openssh-key-v1\0".utf8)
        guard buffer.readBytes(length: magic.count) == magic,
              let cipher = buffer.readSSHString().map({ String(buffer: $0) }),
              buffer.readSSHString() != nil,                       // kdf name
              buffer.readSSHString() != nil,                       // kdf options
              buffer.readInteger(as: UInt32.self) == 1,            // number of keys
              var publicBlob = buffer.readSSHString(),
              let keyType = publicBlob.readSSHString().map({ String(buffer: $0) }),
              let privateSection = buffer.readSSHString() else { return nil }
        self.cipher = cipher
        self.keyType = keyType
        self.privateSection = privateSection
    }
}

extension ByteBuffer {
    /// SSH wire `string`: a uint32 length followed by that many bytes.
    mutating func readSSHString() -> ByteBuffer? {
        guard let length = getInteger(at: readerIndex, as: UInt32.self),
              readableBytes >= 4 + Int(length) else { return nil }
        moveReaderIndex(forwardBy: 4)
        return readSlice(length: Int(length))
    }
}
