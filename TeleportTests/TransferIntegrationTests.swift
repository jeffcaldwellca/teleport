import XCTest
import CryptoKit
import TeleportKit
@testable import Teleport

/// Live-server integration tests for the transfer engine. Skipped unless
/// `TELEPORT_IT=1` is in the environment (pass `TEST_RUNNER_TELEPORT_IT=1` to
/// xcodebuild) with the local docker test servers running — start them with
/// `scripts/start-test-servers.sh` (FTP, SFTP, and explicit + implicit FTPS
/// behind a self-signed certificate).
///
/// These verify the properties the app promises: byte-exact round trips,
/// working resume (REST / offset reads), conflict primitives, and that a
/// server's identity is confirmed before credentials are sent.
final class TransferIntegrationTests: XCTestCase {

    private static let password = "testpass"

    private func requireServers() throws {
        guard ProcessInfo.processInfo.environment["TELEPORT_IT"] == "1" else {
            throw XCTSkip("Set TELEPORT_IT=1 with the local docker test servers running")
        }
    }

    private func ftpConnection() -> Connection {
        Connection(name: "it-ftp", host: "127.0.0.1", port: 2121,
                   username: "testuser", connectionProtocol: .ftp)
    }

    private func ftpsConnection(port: Int = 2122) -> Connection {
        Connection(name: "it-ftps", host: "127.0.0.1", port: port,
                   username: "testuser", connectionProtocol: .ftps)
    }

    private func sftpConnection() -> Connection {
        Connection(name: "it-sftp", host: "127.0.0.1", port: 2222,
                   username: "testuser", connectionProtocol: .sftp)
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "teleport-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeRandomFile(in dir: URL, name: String, size: Int) throws -> URL {
        var data = Data(capacity: size)
        var rng = SystemRandomNumberGenerator()
        while data.count < size {
            withUnsafeBytes(of: rng.next()) { data.append(contentsOf: $0) }
        }
        data = data.prefix(size)
        let url = dir.appending(component: name)
        try data.write(to: url)
        return url
    }

    private func sha256(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// An `SFTPClient` with an in-memory-only known-hosts store (never persisted, so each test run starts with no
    /// prior trust) and an unconditional accept in place of the GUI dialog.
    private func sftpTestClient() -> SFTPClient {
        SFTPClient(
            connection: sftpConnection(),
            password: Self.password,
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in true }
        )
    }

    private func roundTrip(
        client: RemoteClient,
        remotePath: String,
        localDir: URL,
        original: URL
    ) async throws {
        try await client.upload(from: original, remotePath: remotePath, resume: false) { _, _ in }

        let downloaded = localDir.appending(component: "downloaded-\(UUID().uuidString).bin")
        try await client.download(remotePath: remotePath, to: downloaded, resume: false) { _, _ in }

        let originalHash   = try sha256(original)
        let downloadedHash = try sha256(downloaded)
        XCTAssertEqual(originalHash, downloadedHash, "Round-tripped file must be byte-identical")
    }

    // MARK: - FTPS

    /// Trusts whatever certificate the test server presents, in a throwaway store.
    private func ftpsTestClient(port: Int = 2122) -> FTPClient {
        FTPClient(
            connection: ftpsConnection(port: port),
            password: Self.password,
            certificateStore: SSHHostKeyStore(storeURL: nil),
            onUntrustedCertificate: { _ in true }
        )
    }

    /// Exercises the whole FTPS data path against vsftpd: PROT P, the
    /// data-channel handshake, and TLS session reuse (which the server requires).
    func test_ftps_uploadDownloadRoundTrip() async throws {
        try requireServers()
        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 1_500_000)

        let client = ftpsTestClient()
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let listing = try await client.listDirectory(at: "/ftp/testuser")
        XCTAssertNotNil(listing)
        try await roundTrip(client: client,
                            remotePath: "/ftp/testuser/ftps-\(UUID().uuidString).bin",
                            localDir: dir, original: original)
    }

    func test_ftps_implicitTLS_uploadDownloadRoundTrip() async throws {
        try requireServers()
        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 400_000)

        let client = ftpsTestClient(port: 990)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        try await roundTrip(client: client,
                            remotePath: "/ftp/testuser/implicit-\(UUID().uuidString).bin",
                            localDir: dir, original: original)
    }

    func test_ftps_untrustedCertificate_failsClosedWhenDeclined() async throws {
        try requireServers()
        let client = FTPClient(
            connection: ftpsConnection(),
            password: Self.password,
            certificateStore: SSHHostKeyStore(storeURL: nil),
            onUntrustedCertificate: { _ in false }
        )
        do {
            try await client.connect()
            XCTFail("A declined certificate must not connect")
        } catch FTPError.untrustedCertificate {
            // expected
        }
    }

    func test_ftps_acceptedCertificate_isRememberedAndNotAskedAgain() async throws {
        try requireServers()
        let store = SSHHostKeyStore(storeURL: nil)

        let first = FTPClient(connection: ftpsConnection(), password: Self.password,
                              certificateStore: store, onUntrustedCertificate: { _ in true })
        try await first.connect()
        await first.disconnect()

        let second = FTPClient(connection: ftpsConnection(), password: Self.password,
                               certificateStore: store, onUntrustedCertificate: { _ in
            XCTFail("An already-accepted certificate must not prompt again")
            return false
        })
        try await second.connect()
        await second.disconnect()
    }

    func test_ftps_certificateDifferentFromTheAcceptedOne_isRejectedWithoutAsking() async throws {
        try requireServers()
        let store = SSHHostKeyStore(storeURL: nil)
        try await store.record(host: "127.0.0.1", port: 2122, fingerprint: "SHA256:" + String(repeating: "00", count: 32))

        let client = FTPClient(connection: ftpsConnection(), password: Self.password,
                               certificateStore: store, onUntrustedCertificate: { _ in
            XCTFail("A changed certificate must be refused outright, not re-offered")
            return true
        })
        do {
            try await client.connect()
            XCTFail("A changed certificate must not connect")
        } catch FTPError.certificateChanged {
            // expected
        }
    }

    // MARK: - FTP

    func test_ftp_uploadDownloadRoundTrip() async throws {
        try requireServers()
        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 1_500_000)

        let client = FTPClient(connection: ftpConnection(), password: Self.password)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        try await roundTrip(client: client,
                            remotePath: "/ftp/testuser/roundtrip-\(UUID().uuidString).bin",
                            localDir: dir, original: original)
    }

    func test_ftp_downloadResume_producesIdenticalFile() async throws {
        try requireServers()
        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 1_000_000)
        let remotePath = "/ftp/testuser/resume-dl-\(UUID().uuidString).bin"

        let client = FTPClient(connection: ftpConnection(), password: Self.password)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        try await client.upload(from: original, remotePath: remotePath, resume: false) { _, _ in }

        // Simulate an interrupted download: a staged partial file with the
        // first 300k bytes, then resume.
        let resumed = dir.appending(component: "resumed.bin")
        try Data(contentsOf: original).prefix(300_000)
            .write(to: DownloadStaging.partialURL(for: resumed))

        try await client.download(remotePath: remotePath, to: resumed, resume: true) { _, _ in }
        XCTAssertEqual(try sha256(original), try sha256(resumed),
                       "Resumed download must reproduce the exact original bytes")
    }

    func test_ftp_uploadResume_producesIdenticalFile() async throws {
        try requireServers()
        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 1_000_000)
        let remotePath = "/ftp/testuser/resume-ul-\(UUID().uuidString).bin"

        let client = FTPClient(connection: ftpConnection(), password: Self.password)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        // Simulate an interrupted upload: put the first 300k on the server,
        // then upload the full file with resume.
        let partial = dir.appending(component: "partial.bin")
        try Data(contentsOf: original).prefix(300_000).write(to: partial)
        try await client.upload(from: partial, remotePath: remotePath, resume: false) { _, _ in }

        try await client.upload(from: original, remotePath: remotePath, resume: true) { _, _ in }

        let downloaded = dir.appending(component: "verify.bin")
        try await client.download(remotePath: remotePath, to: downloaded, resume: false) { _, _ in }
        XCTAssertEqual(try sha256(original), try sha256(downloaded),
                       "Resumed upload must leave the exact original bytes on the server")
    }

    func test_ftp_fileExists_and_missingDownloadFails() async throws {
        try requireServers()
        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 10_000)
        let remotePath = "/ftp/testuser/exists-\(UUID().uuidString).bin"

        let client = FTPClient(connection: ftpConnection(), password: Self.password)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let existsBefore = await client.fileExists(at: remotePath)
        XCTAssertFalse(existsBefore, "fileExists must be false before upload")
        try await client.upload(from: original, remotePath: remotePath, resume: false) { _, _ in }
        let existsAfter = await client.fileExists(at: remotePath)
        XCTAssertTrue(existsAfter, "fileExists must be true after upload (upload-conflict detection relies on it)")

        let dest = dir.appending(component: "missing.bin")
        do {
            try await client.download(remotePath: "/ftp/testuser/no-such-\(UUID().uuidString).bin",
                                      to: dest, resume: false) { _, _ in }
            XCTFail("Downloading a missing file must throw")
        } catch { /* expected */ }
    }

    func test_ftp_listing_mkdir_rename_delete() async throws {
        try requireServers()
        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 5_000)
        let folder = "/ftp/testuser/it-dir-\(UUID().uuidString.prefix(8))"

        let client = FTPClient(connection: ftpConnection(), password: Self.password)
        try await client.connect()
        defer { Task { await client.disconnect() } }

        try await client.createDirectory(at: folder)
        try await client.upload(from: original, remotePath: "\(folder)/a.bin", resume: false) { _, _ in }

        let items = try await client.listDirectory(at: folder)
        XCTAssertEqual(items.map(\.name), ["a.bin"])
        XCTAssertEqual(items.first?.size, 5_000)

        try await client.rename(from: "\(folder)/a.bin", to: "\(folder)/b.bin")
        let renamed = try await client.listDirectory(at: folder)
        XCTAssertEqual(renamed.map(\.name), ["b.bin"])

        try await client.delete(at: "\(folder)/b.bin", isDirectory: false)
        try await client.delete(at: folder, isDirectory: true)
        let existsAfter = await client.fileExists(at: "\(folder)/b.bin")
        XCTAssertFalse(existsAfter)
    }

    // MARK: - SFTP

    func test_sftp_uploadDownloadRoundTrip() async throws {
        try requireServers()

        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 1_500_000)

        let client = sftpTestClient()
        try await client.connect()
        defer { Task { await client.disconnect() } }

        try await roundTrip(client: client,
                            remotePath: "/upload/roundtrip-\(UUID().uuidString).bin",
                            localDir: dir, original: original)
    }

    func test_sftp_downloadResume_producesIdenticalFile() async throws {
        try requireServers()

        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 1_000_000)
        let remotePath = "/upload/resume-dl-\(UUID().uuidString).bin"

        let client = sftpTestClient()
        try await client.connect()
        defer { Task { await client.disconnect() } }

        try await client.upload(from: original, remotePath: remotePath, resume: false) { _, _ in }

        let resumed = dir.appending(component: "resumed.bin")
        try Data(contentsOf: original).prefix(300_000)
            .write(to: DownloadStaging.partialURL(for: resumed))

        try await client.download(remotePath: remotePath, to: resumed, resume: true) { _, _ in }
        XCTAssertEqual(try sha256(original), try sha256(resumed),
                       "Resumed download must reproduce the exact original bytes")
    }

    func test_sftp_uploadResume_producesIdenticalFile() async throws {
        try requireServers()

        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 1_000_000)
        let remotePath = "/upload/resume-ul-\(UUID().uuidString).bin"

        let client = sftpTestClient()
        try await client.connect()
        defer { Task { await client.disconnect() } }

        let partial = dir.appending(component: "partial.bin")
        try Data(contentsOf: original).prefix(300_000).write(to: partial)
        try await client.upload(from: partial, remotePath: remotePath, resume: false) { _, _ in }

        try await client.upload(from: original, remotePath: remotePath, resume: true) { _, _ in }

        let downloaded = dir.appending(component: "verify.bin")
        try await client.download(remotePath: remotePath, to: downloaded, resume: false) { _, _ in }
        XCTAssertEqual(try sha256(original), try sha256(downloaded),
                       "Resumed upload must leave the exact original bytes on the server")
    }

    func test_sftp_setModifiedDate_roundTrip() async throws {
        try requireServers()

        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 10_000)
        let remotePath = "/upload/mtime-\(UUID().uuidString).bin"

        let client = sftpTestClient()
        try await client.connect()
        defer { Task { await client.disconnect() } }

        try await client.upload(from: original, remotePath: remotePath, resume: false) { _, _ in }

        // "Overwrite if newer" depends on this: after upload the remote mtime
        // must be settable to the local file's mtime.
        let target = Date(timeIntervalSinceNow: -86_400)   // yesterday
        await client.setModifiedDate(target, at: remotePath)
        let reported = await client.remoteModifiedDate(at: remotePath)
        let observed = try XCTUnwrap(reported)
        XCTAssertEqual(observed.timeIntervalSince1970, target.timeIntervalSince1970, accuracy: 2,
                       "Remote mtime must round-trip (SETSTAT then stat)")
    }

    /// A first-seen host key must be put to the user before any credentials
    /// leave the machine. With a wrong password and a declined key, an
    /// authentication failure would prove the password was sent first.
    func test_sftp_unknownHostKey_isConfirmedBeforeAuthenticating() async throws {
        try requireServers()
        let client = SFTPClient(
            connection: sftpConnection(),
            password: "definitely-not-the-password",
            hostKeyStore: SSHHostKeyStore(storeURL: nil),
            onUnknownHostKey: { _, _, _ in false }
        )
        do {
            try await client.connect()
            XCTFail("Connecting with a declined host key should throw")
        } catch RemoteClientError.hostKeyUntrusted {
            // expected: asked (and declined) before authentication was attempted
        }
    }

    /// Cancelling a download that was overwriting an existing file must leave
    /// that file exactly as it was, and clean up the staged partial.
    @MainActor
    func test_queue_cancelledOverwrite_sftp_keepsExistingFileAndRemovesPartial() async throws {
        try requireServers()
        let dir = try makeTempDir()
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 12_000_000)
        let remotePath = "/upload/cancel-\(UUID().uuidString).bin"

        let client = sftpTestClient()
        try await client.connect()
        try await client.upload(from: original, remotePath: remotePath, resume: false) { _, _ in }
        await client.disconnect()

        let dest = dir.appending(component: "existing.bin")
        try Data("existing contents".utf8).write(to: dest)

        let queue = TransferQueueViewModel(
            passwordProvider: { _ in Self.password },
            clientFactory: { [self] _, _ in SlowedDownloadClient(base: sftpTestClient()) }
        )
        let task = try XCTUnwrap(queue.enqueue(
            connection: sftpConnection(), direction: .download,
            localURL: dest, remotePath: remotePath, conflictBehavior: .overwrite
        ))
        try await waitUntil(timeout: 30, "first bytes") { task.bytesTransferred > 200_000 }
        queue.cancel(task)

        let partial = DownloadStaging.partialURL(for: dest)
        try await waitUntil(timeout: 30, "partial removed") {
            !FileManager.default.fileExists(atPath: partial.path)
        }
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "existing contents")
    }

    /// End-to-end queue behaviour: pause an in-flight download, verify partial
    /// data is kept, resume, and verify the final file is byte-identical.
    @MainActor
    func test_queue_pauseResume_sftp_producesIdenticalFile() async throws {
        try requireServers()
        let dir = try makeTempDir()
        // Downloaded through SlowedDownloadClient, so it can't finish before the pause.
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 12_000_000)
        let remotePath = "/upload/pause-\(UUID().uuidString).bin"

        let client = sftpTestClient()
        try await client.connect()
        try await client.upload(from: original, remotePath: remotePath, resume: false) { _, _ in }
        await client.disconnect()

        let queue = TransferQueueViewModel(
            passwordProvider: { _ in Self.password },
            clientFactory: { [self] _, _ in SlowedDownloadClient(base: sftpTestClient()) }
        )
        let dest = dir.appending(component: "queued.bin")
        let task = try XCTUnwrap(queue.enqueue(
            connection: sftpConnection(), direction: .download,
            localURL: dest, remotePath: remotePath
        ))

        // Wait until some (but not all) bytes have flowed, then pause.
        try await waitUntil(timeout: 30, "first bytes") {
            task.bytesTransferred > 200_000
        }
        queue.pause(task)
        try await waitUntil(timeout: 30, "paused") { task.status == .paused }

        let partialSize = (try? FileManager.default.attributesOfItem(
            atPath: DownloadStaging.partialURL(for: dest).path)[.size]) as? Int64 ?? 0
        XCTAssertGreaterThan(partialSize, 0, "Pause must keep partial bytes for resume")
        XCTAssertLessThan(partialSize, 12_000_000, "Transfer should not have finished before pause")

        queue.resume(task)
        try await waitUntil(timeout: 120, "completed") { task.status == .completed }
        XCTAssertEqual(try sha256(original), try sha256(dest),
                       "Paused-and-resumed download must be byte-identical")
    }

    /// The queue keeps one connection per worker and, for FTP, runs transfers
    /// on that connection's own control channel. Several files in a row must
    /// each arrive intact over the reused session — plain and TLS.
    @MainActor
    func test_queue_ftpAndFTPS_severalFilesOverOneReusedConnection() async throws {
        try requireServers()
        let savedConcurrency = Preferences.shared.maxConcurrentTransfers
        Preferences.shared.maxConcurrentTransfers = 1
        defer { Preferences.shared.maxConcurrentTransfers = savedConcurrency }

        for connection in [ftpConnection(), ftpsConnection()] {
            let dir = try makeTempDir()
            let queue = TransferQueueViewModel(
                passwordProvider: { _ in Self.password },
                clientFactory: { connection, password in
                    FTPClient(connection: connection, password: password,
                              certificateStore: SSHHostKeyStore(storeURL: nil),
                              onUntrustedCertificate: { _ in true },
                              dedicatedToTransfers: true)
                }
            )
            let run = UUID().uuidString
            var originals: [(local: URL, remote: String)] = []
            for index in 0..<4 {
                let local = try writeRandomFile(in: dir, name: "up-\(index).bin", size: 150_000 + index * 40_000)
                originals.append((local, "/ftp/testuser/reuse-\(run)-\(index).bin"))
            }

            let uploads = try originals.map {
                try XCTUnwrap(queue.enqueue(connection: connection, direction: .upload,
                                            localURL: $0.local, remotePath: $0.remote))
            }
            try await waitUntil(timeout: 60, "uploads over \(connection.connectionProtocol.rawValue)") {
                uploads.allSatisfy { $0.status.isFinal }
            }
            XCTAssertTrue(uploads.allSatisfy { $0.status == .completed }, "\(uploads.map(\.status))")

            let downloads = try originals.enumerated().map { index, original in
                try XCTUnwrap(queue.enqueue(connection: connection, direction: .download,
                                            localURL: dir.appending(component: "down-\(index).bin"),
                                            remotePath: original.remote))
            }
            try await waitUntil(timeout: 60, "downloads over \(connection.connectionProtocol.rawValue)") {
                downloads.allSatisfy { $0.status.isFinal }
            }
            XCTAssertTrue(downloads.allSatisfy { $0.status == .completed }, "\(downloads.map(\.status))")
            for (index, original) in originals.enumerated() {
                XCTAssertEqual(try sha256(original.local),
                               try sha256(dir.appending(component: "down-\(index).bin")))
            }
        }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval,
        _ what: String,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func test_sftp_reconnect_reusesClientSafely() async throws {
        try requireServers()

        let client = sftpTestClient()
        try await client.connect()
        // The browser's self-heal path calls connect() on an existing client —
        // must not leak or fail.
        try await client.connect()
        let items = try await client.listDirectory(at: "/")
        XCTAssertTrue(items.contains { $0.name == "upload" })
        await client.disconnect()
    }
}

/// Forwards to `base`, holding each download progress tick for a moment so a
/// test can reliably pause or cancel a transfer while it is still in flight.
private final class SlowedDownloadClient: RemoteClient, @unchecked Sendable {
    private let base: RemoteClient
    init(base: RemoteClient) { self.base = base }

    func download(remotePath: String, to localURL: URL, resume: Bool,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await base.download(remotePath: remotePath, to: localURL, resume: resume) { bytes, total in
            Thread.sleep(forTimeInterval: 0.01)
            progress(bytes, total)
        }
    }

    func connect() async throws { try await base.connect() }
    func disconnect() async { await base.disconnect() }
    func listDirectory(at absolutePath: String) async throws -> [FileItem] {
        try await base.listDirectory(at: absolutePath)
    }
    func upload(from localURL: URL, remotePath: String, resume: Bool,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await base.upload(from: localURL, remotePath: remotePath, resume: resume, progress: progress)
    }
    func keepAlive() async { await base.keepAlive() }
    func ping() async throws { try await base.ping() }
    func createDirectory(at absolutePath: String) async throws { try await base.createDirectory(at: absolutePath) }
    func delete(at absolutePath: String, isDirectory: Bool) async throws {
        try await base.delete(at: absolutePath, isDirectory: isDirectory)
    }
    func rename(from: String, to: String) async throws { try await base.rename(from: from, to: to) }
    func setPermissions(_ octal: Int, at absolutePath: String) async throws {
        try await base.setPermissions(octal, at: absolutePath)
    }
    func setOwnership(owner: String, group: String, at absolutePath: String) async throws {
        try await base.setOwnership(owner: owner, group: group, at: absolutePath)
    }
    func remoteModifiedDate(at remotePath: String) async -> Date? { await base.remoteModifiedDate(at: remotePath) }
    func setModifiedDate(_ date: Date, at remotePath: String) async { await base.setModifiedDate(date, at: remotePath) }
    func fileExists(at remotePath: String) async -> Bool { await base.fileExists(at: remotePath) }
}
