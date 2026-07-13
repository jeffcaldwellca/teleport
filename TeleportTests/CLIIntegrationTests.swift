import XCTest
import Security

/// Live-server integration tests for the `tport` CLI. Skipped unless
/// `TELEPORT_IT=1` is set, with the same docker containers as
/// `TransferIntegrationTests.swift` (see that file's header for exact
/// `docker run` commands).
final class CLIIntegrationTests: XCTestCase {

    private func requireServers() throws {
        guard ProcessInfo.processInfo.environment["TELEPORT_IT"] == "1" else {
            throw XCTSkip("Set TELEPORT_IT=1 with the local docker test servers running")
        }
    }

    private func tportBinaryURL() throws -> URL {
        // Built by `swift build` in TeleportKit/ ahead of running this suite.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportTests/
            .deletingLastPathComponent()  // repo root
            .appending(path: "TeleportKit/.build/debug/tport")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Build tport first: cd TeleportKit && swift build")
        }
        return url
    }

    private func run(_ args: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try tportBinaryURL()
        process.arguments = args
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }

    func test_ftp_ls_listsUploadedFile() throws {
        try requireServers()
        let dir = FileManager.default.temporaryDirectory.appending(component: "tport-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(component: "hello.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let remotePath = "/ftp/testuser/tport-it-\(UUID().uuidString).txt"
        let put = try run(["put", file.path, "ftp://testuser:testpass@127.0.0.1:2121\(remotePath)"])
        XCTAssertEqual(put.exitCode, 0, put.stderr)

        let ls = try run(["ls", "ftp://testuser:testpass@127.0.0.1:2121/ftp/testuser", "--json"])
        XCTAssertEqual(ls.exitCode, 0, ls.stderr)
        XCTAssertTrue(ls.stdout.contains((remotePath as NSString).lastPathComponent))
    }

    func test_sftp_unknownHostKey_failsClosedWithoutAcceptFlag() throws {
        try requireServers()
        let knownHosts = FileManager.default.temporaryDirectory
            .appending(component: "tport-it-known-hosts-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: knownHosts) }

        let result = try run([
            "test", "sftp://testuser:testpass@127.0.0.1:2222/upload",
            "--known-hosts", knownHosts.path,
        ])
        XCTAssertEqual(result.exitCode, 6, result.stderr)   // TportExitCode.hostKey
    }

    func test_sftp_acceptNewHostkey_thenTrustsOnSubsequentRun() throws {
        try requireServers()
        let knownHosts = FileManager.default.temporaryDirectory
            .appending(component: "tport-it-known-hosts-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: knownHosts) }

        let first = try run([
            "test", "sftp://testuser:testpass@127.0.0.1:2222/upload",
            "--known-hosts", knownHosts.path, "--accept-new-hostkey",
        ])
        XCTAssertEqual(first.exitCode, 0, first.stderr)

        let second = try run([
            "test", "sftp://testuser:testpass@127.0.0.1:2222/upload",
            "--known-hosts", knownHosts.path,
        ])
        XCTAssertEqual(second.exitCode, 0, second.stderr)   // trusted from the first run, no --accept needed
    }

    func test_get_resume_producesCompleteFile() throws {
        try requireServers()
        let dir = FileManager.default.temporaryDirectory.appending(component: "tport-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        var data = Data(count: 500_000)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 500_000, $0.baseAddress!) }
        let original = dir.appending(component: "original.bin")
        try data.write(to: original)

        let remotePath = "/upload/tport-it-resume-\(UUID().uuidString).bin"
        let put = try run(["put", original.path, "sftp://testuser:testpass@127.0.0.1:2222\(remotePath)", "--accept-new-hostkey"])
        XCTAssertEqual(put.exitCode, 0, put.stderr)

        let downloaded = dir.appending(component: "downloaded.bin")
        try data.prefix(200_000).write(to: downloaded)   // simulate a partial prior download

        let get = try run([
            "get", "sftp://testuser:testpass@127.0.0.1:2222\(remotePath)", downloaded.path,
            "--resume", "--accept-new-hostkey", "--on-conflict", "overwrite",
        ])
        XCTAssertEqual(get.exitCode, 0, get.stderr)
        XCTAssertEqual(try Data(contentsOf: downloaded), data)
    }

    func test_mkdir_rm_recursive() throws {
        try requireServers()
        let folder = "/ftp/testuser/tport-it-dir-\(UUID().uuidString.prefix(8))"

        let mkdir = try run(["mkdir", "ftp://testuser:testpass@127.0.0.1:2121\(folder)"])
        XCTAssertEqual(mkdir.exitCode, 0, mkdir.stderr)

        let ls = try run(["ls", "ftp://testuser:testpass@127.0.0.1:2121/ftp/testuser"])
        XCTAssertEqual(ls.exitCode, 0, ls.stderr)
        XCTAssertTrue(ls.stdout.contains(folder))

        let rm = try run(["rm", "ftp://testuser:testpass@127.0.0.1:2121\(folder)", "--recursive"])
        XCTAssertEqual(rm.exitCode, 0, rm.stderr)
    }
}
