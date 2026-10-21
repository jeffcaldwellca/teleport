import XCTest
import NIOCore
import NIOEmbedded
@testable import Citadel

/// The vendored SFTP packet parser must not let a server dictate how much
/// memory the client buffers: a declared length of zero can never complete,
/// and a huge one makes the decoder hoard bytes until it arrives.
final class SFTPMessageParserTests: XCTestCase {

    private func feed(_ bytes: [UInt8]) throws -> SFTPMessage? {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
        defer { _ = try? channel.finish() }
        try channel.writeInbound(ByteBuffer(bytes: bytes))
        return try channel.readInbound(as: SFTPMessage.self)
    }

    /// A packet is `uint32 length, byte type, payload`; the length counts the
    /// type byte.
    private func packet(type: UInt8, payload: [UInt8]) -> [UInt8] {
        let length = UInt32(1 + payload.count)
        return [UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff), type] + payload
    }

    func test_decodesAWellFormedVersionPacket() throws {
        let message = try feed(packet(type: 2, payload: [0, 0, 0, 3]))
        guard case .version = message else { return XCTFail("Expected a version message, got \(String(describing: message))") }
    }

    func test_rejectsAZeroLength_insteadOfWaitingForever() {
        XCTAssertThrowsError(try feed([0, 0, 0, 0, 2])) { error in
            XCTAssertTrue(error is SFTPError, "\(error)")
        }
    }

    func test_rejectsAnAbsurdLength_insteadOfBufferingTowardsIt() {
        // 4 GiB declared, a few bytes delivered: without a cap the decoder
        // just keeps asking for more.
        XCTAssertThrowsError(try feed([0xff, 0xff, 0xff, 0xff, 104, 0, 0, 0, 1])) { error in
            XCTAssertTrue(error is SFTPError, "\(error)")
        }
    }
}
