import XCTest
import TeleportKit

/// `FTPClient` against a scripted in-process server that closes the control
/// connection: writes to the dead socket must fail cleanly.
final class FTPDeadSocketTests: XCTestCase {

    private var server: FakeFTPServer!

    override func setUpWithError() throws {
        server = try FakeFTPServer()
    }

    override func tearDownWithError() throws {
        server.stop()
    }

    private func makeClient() -> FTPClient {
        FTPClient(
            connection: Connection(host: "127.0.0.1", port: server.port,
                                   username: "test", connectionProtocol: .ftp),
            password: ""
        )
    }

    func test_writingToServerClosedConnection_doesNotKillTheProcess() async throws {
        server.dropControlAfterLogin = true
        let client = makeClient()
        try await client.connect()

        // The first write after the server's close provokes a reset; a second
        // write on the reset socket raises SIGPIPE unless it's suppressed.
        _ = await client.fileExists(at: "/a")
        try await Task.sleep(for: .milliseconds(200))
        _ = await client.fileExists(at: "/a")
    }

    func test_failedKeepAlive_dropsTheSocketSoTheNextOperationReportsNotConnected() async throws {
        server.dropControlAfterLogin = true
        let client = makeClient()
        try await client.connect()

        await client.keepAlive()

        do {
            _ = try await client.listDirectory(at: "/")
            XCTFail("Listing on a dropped connection should throw")
        } catch RemoteClientError.notConnected {
            // expected: callers treat this as "reconnect"
        }
    }
}
