// AES-GCM transport protection for SSH, in OpenSSH mode, with the MAC
// negotiation that hardened servers insist on.
//
// SwiftNIO SSH's own AES-GCM schemes offer no MAC name (GCM authenticates by
// itself), and the library then advertises a single stand-in, `hmac-sha2-256`.
// A server configured the way ssh-audit and most VPS hardening guides
// recommend — only `*-etm@openssh.com` MACs — shares no name with that list,
// and the key exchange fails before the host key is even seen, although both
// sides would happily use AES-GCM and ignore the MAC. These schemes are the
// library's implementation with one difference: they advertise OpenSSH's
// whole default MAC list, which is harmless because the negotiated MAC is
// never used with GCM (RFC 5647 §5.1; OpenSSH logs it as "<implicit>").
//
// The packet handling is adapted from swift-nio-ssh's `AESGCM.swift`
// (Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors, licensed
// under Apache License v2.0, SPDX-License-Identifier: Apache-2.0); the
// library's own classes are internal, so they can't be subclassed.

import Crypto
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOSSH
import Citadel

/// The transport algorithms every SFTP connection (and host-key probe) uses.
enum SSHTransport {
    static var schemes: [NIOSSHTransportProtection.Type] {
        [AES256GCMOpenSSH.self, AES128GCMOpenSSH.self]
    }

    /// For `SSHClient.connect(algorithms:)`.
    static var algorithms: SSHAlgorithms {
        var algorithms = SSHAlgorithms()
        algorithms.transportProtectionSchemes = .replace(with: schemes)
        return algorithms
    }

    /// OpenSSH's default `MACs`, so any server that speaks AES-GCM agrees on
    /// a MAC name whatever its policy. None of these is ever used: GCM
    /// carries its own tag.
    static let advertisedMACNames = [
        "hmac-sha2-256-etm@openssh.com", "hmac-sha2-512-etm@openssh.com",
        "umac-64-etm@openssh.com", "umac-128-etm@openssh.com", "hmac-sha1-etm@openssh.com",
        "hmac-sha2-256", "hmac-sha2-512", "umac-64@openssh.com", "umac-128@openssh.com", "hmac-sha1",
    ]
}

/// Shared AES-GCM packet handling; the subclasses supply the key size and
/// cipher name.
class AESGCMOpenSSHTransportProtection: NIOSSHTransportProtection {
    enum Failure: Error {
        case invalidKeySize
        case invalidEncryptedPacketLength
        case invalidDecryptedPlaintextLength
        case invalidNonceLength
        case insufficientPadding
        case excessPadding
    }

    private var outboundEncryptionKey: SymmetricKey
    private var inboundEncryptionKey: SymmetricKey
    private var outboundNonce: AESGCMNonce
    private var inboundNonce: AESGCMNonce
    private let encryptionKeySize: Int

    class var cipherName: String { fatalError("Subclasses name the cipher") }
    class var macNames: [String] { SSHTransport.advertisedMACNames }
    class var encryptionKeySize: Int { fatalError("Subclasses set the key size") }
    static var cipherBlockSize: Int { 16 }
    var macBytes: Int { 16 }

    class func keySizes(forMac mac: String?) throws -> ExpectedKeySizes {
        // The MAC is ignored: GCM's tag authenticates the packet.
        ExpectedKeySizes(ivSize: 12, encryptionKeySize: encryptionKeySize, macKeySize: 16)
    }

    required init(initialKeys: NIOSSHSessionKeys, mac: String?) throws {
        let keySize = Self.encryptionKeySize
        guard initialKeys.outboundEncryptionKey.bitCount == keySize * 8,
              initialKeys.inboundEncryptionKey.bitCount == keySize * 8 else {
            throw Failure.invalidKeySize
        }
        encryptionKeySize = keySize
        outboundEncryptionKey = initialKeys.outboundEncryptionKey
        inboundEncryptionKey = initialKeys.inboundEncryptionKey
        outboundNonce = try AESGCMNonce(keyExchangeResult: initialKeys.initialOutboundIV)
        inboundNonce = try AESGCMNonce(keyExchangeResult: initialKeys.initialInboundIV)
    }

    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        guard newKeys.outboundEncryptionKey.bitCount == encryptionKeySize * 8,
              newKeys.inboundEncryptionKey.bitCount == encryptionKeySize * 8 else {
            throw Failure.invalidKeySize
        }
        outboundEncryptionKey = newKeys.outboundEncryptionKey
        inboundEncryptionKey = newKeys.inboundEncryptionKey
        outboundNonce = try AESGCMNonce(keyExchangeResult: newKeys.initialOutboundIV)
        inboundNonce = try AESGCMNonce(keyExchangeResult: newKeys.initialInboundIV)
    }

    func decryptFirstBlock(_: inout ByteBuffer) throws {
        // The length field is sent in the clear (as associated data).
    }

    func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        var plaintext: Data
        do {
            // 4 bytes of length, then ciphertext (a non-empty multiple of the
            // block size), then the 16-byte tag.
            guard let lengthView = source.readSlice(length: 4)?.readableBytesView,
                  let ciphertextView = source.readSlice(length: source.readableBytes - 16)?.readableBytesView,
                  let tagView = source.readSlice(length: 16)?.readableBytesView,
                  ciphertextView.count > 0, ciphertextView.count % Self.cipherBlockSize == 0 else {
                throw Failure.invalidEncryptedPacketLength
            }
            let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: inboundNonce),
                                                  ciphertext: ciphertextView, tag: tagView)
            plaintext = try AES.GCM.open(sealedBox, using: inboundEncryptionKey, authenticating: lengthView)
            guard plaintext.count % Self.cipherBlockSize == 0, plaintext.count == ciphertextView.count else {
                throw Failure.invalidDecryptedPlaintextLength
            }
        }
        inboundNonce.increment()

        // Strip the padding-length byte and the padding, then write the
        // payload back over the (uniquely held) source so no copy is needed.
        try plaintext.removePaddingBytes()
        source.moveReaderIndex(to: source.readerIndex - plaintext.count)
        source.setContiguousBytes(plaintext, at: source.readerIndex)
        return source.readSlice(length: plaintext.count)!
    }

    func encryptPacket(_ packet: NIOSSHEncryptablePayload, to outboundBuffer: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let packetLengthIndex = outboundBuffer.writerIndex
        let packetLengthLength = MemoryLayout<UInt32>.size
        let packetPaddingIndex = outboundBuffer.writerIndex + packetLengthLength
        let packetPaddingLength = MemoryLayout<UInt8>.size
        outboundBuffer.moveWriterIndex(forwardBy: packetLengthLength + packetPaddingLength)

        let payloadBytes = outboundBuffer.writeEncryptablePayload(packet)

        // Padding-length byte + payload + padding must fill whole blocks,
        // with at least 4 bytes of (random) padding. The length field is not
        // encrypted, so it stays out of the count.
        var encryptedBufferSize = payloadBytes + packetPaddingLength
        var necessaryPaddingBytes = Self.cipherBlockSize - (encryptedBufferSize % Self.cipherBlockSize)
        if necessaryPaddingBytes < 4 {
            necessaryPaddingBytes += Self.cipherBlockSize
        }
        encryptedBufferSize += outboundBuffer.writeSSHPaddingBytes(count: necessaryPaddingBytes)
        precondition(encryptedBufferSize % Self.cipherBlockSize == 0, "Miscounted buffer size: \(encryptedBufferSize)")

        outboundBuffer.setInteger(UInt32(encryptedBufferSize), at: packetLengthIndex)
        outboundBuffer.setInteger(UInt8(necessaryPaddingBytes), at: packetPaddingIndex)

        let sealedBox = try AES.GCM.seal(
            outboundBuffer.viewBytes(at: packetPaddingIndex, length: encryptedBufferSize)!,
            using: outboundEncryptionKey,
            nonce: try AES.GCM.Nonce(data: outboundNonce),
            authenticating: outboundBuffer.viewBytes(at: packetLengthIndex, length: packetLengthLength)!
        )
        assert(sealedBox.ciphertext.count == encryptedBufferSize)

        outboundBuffer.setContiguousBytes(sealedBox.ciphertext, at: packetPaddingIndex)
        let tagLength = outboundBuffer.writeContiguousBytes(sealedBox.tag)
        precondition(tagLength == macBytes, "Unexpected short tag")
        outboundNonce.increment()
    }
}

/// `aes128-gcm@openssh.com`.
class AES128GCMOpenSSH: AESGCMOpenSSHTransportProtection {
    override class var cipherName: String { "aes128-gcm@openssh.com" }
    override class var encryptionKeySize: Int { 16 }
}

/// `aes256-gcm@openssh.com`.
class AES256GCMOpenSSH: AESGCMOpenSSHTransportProtection {
    override class var cipherName: String { "aes256-gcm@openssh.com" }
    override class var encryptionKeySize: Int { 32 }
}

// MARK: - Nonce

/// The 12-byte AES-GCM nonce as SSH uses it (RFC 5647 §7.1): a 4-byte fixed
/// field and an 8-byte big-endian invocation counter, incremented per packet.
/// Stored in 16 bytes (the first 4 unused) so it can be handed to CryptoKit
/// through `DataProtocol` without allocating.
struct AESGCMNonce {
    private var representation: (UInt64, UInt64) = (0, 0)

    init(keyExchangeResult: [UInt8]) throws {
        guard keyExchangeResult.count == 12 else {
            throw AESGCMOpenSSHTransportProtection.Failure.invalidNonceLength
        }
        withUnsafeMutableBytes(of: &representation) { pointer in
            let nonceBytes = UnsafeMutableRawBufferPointer(rebasing: pointer[4...])
            precondition(nonceBytes.count == 12)
            nonceBytes.copyBytes(from: keyExchangeResult)
        }
    }

    mutating func increment() {
        // The counter lives in the second word in network byte order;
        // overflow is expected and allowed.
        representation.1 = (UInt64(bigEndian: representation.1) &+ 1).bigEndian
    }
}

extension AESGCMNonce: RandomAccessCollection {
    struct Index: Strideable, Comparable, Hashable {
        fileprivate var offset: Int
        func advanced(by n: Int) -> Index { Index(offset: offset + n) }
        func distance(to other: Index) -> Int { other.offset - offset }
        static func < (lhs: Index, rhs: Index) -> Bool { lhs.offset < rhs.offset }
    }

    var startIndex: Index { Index(offset: 4) }
    var endIndex: Index { Index(offset: 16) }
    func index(after i: Index) -> Index { Index(offset: i.offset + 1) }

    subscript(position: Index) -> UInt8 {
        precondition(position.offset >= 4 && position.offset < 16, "Invalid nonce index")
        return Swift.withUnsafeBytes(of: representation) { $0[position.offset] }
    }
}

extension AESGCMNonce: ContiguousBytes {
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try Swift.withUnsafeBytes(of: representation) { pointer in
            try body(UnsafeRawBufferPointer(rebasing: pointer[4...]))
        }
    }
}

extension AESGCMNonce: DataProtocol {
    var regions: CollectionOfOne<AESGCMNonce> { .init(self) }
}

private extension Data {
    /// Drops the padding-length byte and the padding it announces.
    mutating func removePaddingBytes() throws {
        guard let paddingLength = first, paddingLength >= 4 else {
            throw AESGCMOpenSSHTransportProtection.Failure.insufficientPadding
        }
        let contentStart = index(after: startIndex)
        guard let contentEnd = index(endIndex, offsetBy: -Int(paddingLength), limitedBy: contentStart) else {
            throw AESGCMOpenSSHTransportProtection.Failure.excessPadding
        }
        self = self[contentStart ..< contentEnd]
    }
}
