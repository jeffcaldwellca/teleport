import XCTest
import CryptoKit
import TeleportKit
@testable import Teleport

/// Live-server integration tests for the transfer engine. Skipped unless
/// `TELEPORT_IT=1` is in the environment (pass `TEST_RUNNER_TELEPORT_IT=1` to
/// xcodebuild) with local test servers running:
///
///   docker run -d --name teleport-it-ftp -p 2121:21 -p 30000-30009:30000-30009 \
///     -e USERS="testuser|testpass" -e ADDRESS=127.0.0.1 \
///     -e MIN_PORT=30000 -e MAX_PORT=30009 delfer/alpine-ftp-server
///   docker run -d --name teleport-it-sftp -p 2222:22 atmoz/sftp testuser:testpass:::upload
///
/// These verify the properties the app promises: byte-exact round trips,
/// working resume (REST / offset reads), and conflict primitives.
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

    /// Only `test_queue_pauseResume_sftp_producesIdenticalFile` still needs this:
    /// it exercises the queue end-to-end through the app's real
    /// `RemoteClientFactory`, which wires `SFTPClient`'s `onUnknownHostKey` to
    /// this UI dialog. Every other SFTP test constructs `SFTPClient` directly
    /// via `sftpTestClient()` below and injects trust without a dialog.
    private func autoAcceptHostKeys() -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                if HostKeyConfirmation.shared.pending != nil {
                    HostKeyConfirmation.shared.accept()
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// An `SFTPClient` for direct (non-queue) tests: an in-memory-only
    /// known-hosts store (never persisted, so each test run starts with no
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

        // Simulate an interrupted download: a partial local file with the
        // first 300k bytes, then resume.
        let partial = dir.appending(component: "resumed.bin")
        try Data(contentsOf: original).prefix(300_000).write(to: partial)

        try await client.download(remotePath: remotePath, to: partial, resume: true) { _, _ in }
        XCTAssertEqual(try sha256(original), try sha256(partial),
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

        let partial = dir.appending(component: "resumed.bin")
        try Data(contentsOf: original).prefix(300_000).write(to: partial)

        try await client.download(remotePath: remotePath, to: partial, resume: true) { _, _ in }
        XCTAssertEqual(try sha256(original), try sha256(partial),
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

    /// End-to-end queue behaviour: pause an in-flight download, verify partial
    /// data is kept, resume, and verify the final file is byte-identical.
    @MainActor
    func test_queue_pauseResume_sftp_producesIdenticalFile() async throws {
        try requireServers()
        let accept = autoAcceptHostKeys()
        defer { accept.cancel() }

        let dir = try makeTempDir()
        // Large enough that the emulated docker sshd can't finish before pause.
        let original = try writeRandomFile(in: dir, name: "original.bin", size: 12_000_000)
        let remotePath = "/upload/pause-\(UUID().uuidString).bin"

        let client = sftpTestClient()
        try await client.connect()
        try await client.upload(from: original, remotePath: remotePath, resume: false) { _, _ in }
        await client.disconnect()

        let queue = TransferQueueViewModel(passwordProvider: { _ in Self.password })
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

        let partialSize = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]) as? Int64 ?? 0
        XCTAssertGreaterThan(partialSize, 0, "Pause must keep partial bytes for resume")
        XCTAssertLessThan(partialSize, 12_000_000, "Transfer should not have finished before pause")

        queue.resume(task)
        try await waitUntil(timeout: 120, "completed") { task.status == .completed }
        XCTAssertEqual(try sha256(original), try sha256(dest),
                       "Paused-and-resumed download must be byte-identical")
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
