import XCTest
import NIOCore
import NIOPosix
import NIOSSH
import Citadel
@testable import TeleportKit

/// A server that stops answering mid-transfer must not hold Cancel (or the
/// transfer queue's stall watchdog) hostage.
final class SFTPStalledTransferTests: XCTestCase {

    private final class AcceptAnyPassword: NIOSSHServerUserAuthenticationDelegate {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            responsePromise.succeed(.success)
        }
    }

    /// One 64 MiB file whose reads are never answered.
    private struct NeverAnswers: SFTPDelegate {
        struct Handle: SFTPFileHandle {
            func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
                try await Task.sleep(for: .seconds(3600))
                return ByteBuffer()
            }
            func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode { .ok }
            func close() async throws -> SFTPStatusCode {
                try await Task.sleep(for: .seconds(3600))
                return .ok
            }
            func readFileAttributes() async throws -> SFTPFileAttributes { NeverAnswers.attributes }
            func setFileAttributes(to attributes: SFTPFileAttributes) async throws {}
        }
        static var attributes: SFTPFileAttributes {
            var attrs = SFTPFileAttributes()
            attrs.size = 64 * 1024 * 1024
            return attrs
        }

        func realPath(for path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
            [SFTPPathComponent(filename: path, longname: path, attributes: .none)]
        }
        func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes { Self.attributes }
        func openFile(_ filePath: String, withAttributes: SFTPFileAttributes, flags: SFTPOpenFileFlags, context: SSHContext) async throws -> SFTPFileHandle { Handle() }
        func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle { throw SFTPError.invalidResponse }
        func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode { .failure }
        func createDirectory(_ filePath: String, withAttributes: SFTPFileAttributes, context: SSHContext) async throws -> SFTPStatusCode { .failure }
        func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode { .failure }
        func setFileAttributes(to attributes: SFTPFileAttributes, atPath path: String, context: SSHContext) async throws -> SFTPStatusCode { .failure }
        func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode { .failure }
        func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] { throw SFTPError.invalidResponse }
        func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode { .failure }
    }

    private var server: SSHServer?

    override func tearDown() async throws {
        try? await server?.close()
    }

    private func freePort() throws -> Int {
        let probe = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? probe.close().wait() }
        return try XCTUnwrap(probe.localAddress?.port)
    }

    func test_cancellingADownloadTheServerStoppedAnswering_stopsIt() async throws {
        let port = try freePort()
        let server = try await SSHServer.host(
            host: "127.0.0.1", port: port,
            hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
            authenticationDelegate: AcceptAnyPassword()
        )
        server.enableSFTP(withDelegate: NeverAnswers())
        self.server = server

        let client = SFTPClient(
            connection: Connection(host: "127.0.0.1", port: port, username: "alice", connectionProtocol: .sftp),
            password: "secret",
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true },
            agent: nil
        )
        try await client.connect()
        let local = FileManager.default.temporaryDirectory.appending(component: "sftp-stalled-\(UUID().uuidString)")
        defer { DownloadStaging.discardPartial(for: local) }

        let download = Task { try await client.download(remotePath: "/big.bin", to: local, resume: false) { _, _ in } }
        try await Task.sleep(for: .seconds(1))
        let cancelledAt = Date()
        download.cancel()
        _ = try? await download.value
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5)

        let disconnectStarted = Date()
        await client.disconnect()
        XCTAssertLessThan(Date().timeIntervalSince(disconnectStarted), 10)
    }
}
