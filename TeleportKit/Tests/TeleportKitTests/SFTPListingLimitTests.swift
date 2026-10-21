import XCTest
import NIOCore
import NIOPosix
import NIOSSH
import Citadel

/// The vendored Citadel SFTP client against a scripted SFTP server: loops
/// the server drives (realpath until it settles, readdir until EOF) must end
/// even when the server never lets them.
final class SFTPListingLimitTests: XCTestCase {

    // MARK: - Scripted server

    private final class AcceptAnyPassword: NIOSSHServerUserAuthenticationDelegate {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .password
        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            responsePromise.succeed(.success)
        }
    }

    private struct ScriptedSFTP: SFTPDelegate {
        enum Behaviour {
            /// Every realpath answer differs from the question.
            case realPathNeverSettles
            /// A directory with this many entries, one per readdir reply.
            case directoryEntries(Int)
        }
        let behaviour: Behaviour

        struct Listing: SFTPDirectoryHandle {
            let count: Int
            func listFiles(context: SSHContext) async throws -> [SFTPFileListing] {
                (0..<count).map { SFTPFileListing(path: [component("file-\($0)")]) }
            }
        }

        func realPath(for path: String, context: SSHContext) async throws -> [SFTPPathComponent] {
            switch behaviour {
            case .realPathNeverSettles: return [component(path + "/again")]
            case .directoryEntries:     return [component(path)]
            }
        }
        func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
            guard case .directoryEntries(let count) = behaviour else { throw SFTPError.invalidResponse }
            return Listing(count: count)
        }

        // Not exercised here.
        func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes { throw SFTPError.invalidResponse }
        func openFile(_ filePath: String, withAttributes: SFTPFileAttributes, flags: SFTPOpenFileFlags, context: SSHContext) async throws -> SFTPFileHandle { throw SFTPError.invalidResponse }
        func removeFile(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode { throw SFTPError.invalidResponse }
        func createDirectory(_ filePath: String, withAttributes: SFTPFileAttributes, context: SSHContext) async throws -> SFTPStatusCode { throw SFTPError.invalidResponse }
        func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode { throw SFTPError.invalidResponse }
        func setFileAttributes(to attributes: SFTPFileAttributes, atPath path: String, context: SSHContext) async throws -> SFTPStatusCode { throw SFTPError.invalidResponse }
        func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode { throw SFTPError.invalidResponse }
        func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] { throw SFTPError.invalidResponse }
        func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode { throw SFTPError.invalidResponse }
    }

    private static func component(_ name: String) -> SFTPPathComponent {
        SFTPPathComponent(filename: name, longname: name, attributes: .none)
    }

    private var server: SSHServer?
    private var client: SSHClient?

    override func tearDown() async throws {
        try? await client?.close()
        try? await server?.close()
    }

    /// Citadel's server doesn't report the port it bound, so find a free one first.
    private func freePort() throws -> Int {
        let probe = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).wait()
        defer { try? probe.close().wait() }
        return try XCTUnwrap(probe.localAddress?.port)
    }

    private func openSFTP(against behaviour: ScriptedSFTP.Behaviour) async throws -> Citadel.SFTPClient {
        let port = try freePort()
        let server = try await SSHServer.host(
            host: "127.0.0.1", port: port,
            hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
            authenticationDelegate: AcceptAnyPassword()
        )
        server.enableSFTP(withDelegate: ScriptedSFTP(behaviour: behaviour))
        self.server = server
        let client = try await SSHClient.connect(
            host: "127.0.0.1", port: port,
            authenticationMethod: .passwordBased(username: "alice", password: "secret"),
            hostKeyValidator: .acceptAnything(), reconnect: .never
        )
        self.client = client
        return try await client.openSFTP()
    }

    private struct TimedOut: Error {}

    /// Fails with `TimedOut` instead of hanging the suite when a loop never
    /// ends. A loop stuck awaiting the server can't be cancelled, so the
    /// timeout closes the connection: its pending request then fails, the
    /// loop throws, and the task group can finish.
    private func within<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let client = self.client
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                try? await client?.close()
                throw TimedOut()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Tests

    func test_realPathThatNeverSettles_isGivenUpOn() async throws {
        let sftp = try await openSFTP(against: .realPathNeverSettles)
        do {
            _ = try await within(seconds: 10) { try await sftp.listDirectory(atPath: "/") }
            XCTFail("Expected the listing to be refused")
        } catch is TimedOut {
            XCTFail("The realpath loop never ended")
        } catch {
            // Any protocol error is the right outcome.
        }
    }

    func test_directoryWithMoreEntriesThanAllowed_isRefused() async throws {
        let sftp = try await openSFTP(against: .directoryEntries(5))
        do {
            _ = try await within(seconds: 10) { try await sftp.listDirectory(atPath: "/", maximumEntries: 3) }
            XCTFail("Expected the listing to be refused")
        } catch SFTPError.directoryListingTooLarge(let limit) {
            XCTAssertEqual(limit, 3)
        }
    }

    func test_directoryWithinTheLimit_isListedInFull() async throws {
        let sftp = try await openSFTP(against: .directoryEntries(3))
        let names = try await within(seconds: 10) { try await sftp.listDirectory(atPath: "/", maximumEntries: 3) }
        XCTAssertEqual(names.flatMap(\.components).map(\.filename), ["file-0", "file-1", "file-2"])
    }
}
