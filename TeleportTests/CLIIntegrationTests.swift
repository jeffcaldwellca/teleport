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

    /// - Parameter environment: variables to set for the child. The user's
    ///   own `SSH_AUTH_SOCK` is always removed first so tests never reach
    ///   their real ssh-agent.
    private func run(_ args: [String], environment: [String: String] = [:]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try tportBinaryURL()
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "SSH_AUTH_SOCK")
        env.removeValue(forKey: "TELEPORT_KEY_PASSPHRASE")
        process.environment = env.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
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
        // Isolated trust store: the user's real ~/.teleport/known_hosts.json may
        // hold a key from an earlier test container on this same port.
        let knownHosts = dir.appending(component: "known_hosts.json").path
        let put = try run(["put", original.path, "sftp://testuser:testpass@127.0.0.1:2222\(remotePath)",
                           "--accept-new-hostkey", "--known-hosts", knownHosts])
        XCTAssertEqual(put.exitCode, 0, put.stderr)

        let downloaded = dir.appending(component: "downloaded.bin")
        try data.prefix(200_000).write(to: downloaded)   // simulate a partial prior download

        let get = try run([
            "get", "sftp://testuser:testpass@127.0.0.1:2222\(remotePath)", downloaded.path,
            "--resume", "--accept-new-hostkey", "--on-conflict", "overwrite",
            "--known-hosts", knownHosts,
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

    func test_stat_correctlyIdentifiesDirectory() throws {
        try requireServers()
        let folder = "/ftp/testuser/tport-it-statdir-\(UUID().uuidString.prefix(8))"
        let mkdir = try run(["mkdir", "ftp://testuser:testpass@127.0.0.1:2121\(folder)"])
        XCTAssertEqual(mkdir.exitCode, 0, mkdir.stderr)
        addTeardownBlock { _ = try? self.run(["rm", "ftp://testuser:testpass@127.0.0.1:2121\(folder)", "--recursive"]) }

        // Before the fix, stat used SIZE-based fileExists (undefined for
        // directories on most FTP servers) and hardcoded isDirectory: false.
        let stat = try run(["stat", "ftp://testuser:testpass@127.0.0.1:2121\(folder)", "--json"])
        XCTAssertEqual(stat.exitCode, 0, stat.stderr)
        XCTAssertTrue(stat.stdout.contains("\"isDirectory\":true"), stat.stdout)
    }

    func test_mkdir_parents_isIdempotent() throws {
        try requireServers()
        let folder = "/ftp/testuser/tport-it-idem-\(UUID().uuidString.prefix(8))/nested"
        addTeardownBlock {
            _ = try? self.run(["rm", "ftp://testuser:testpass@127.0.0.1:2121\(folder)", "--recursive"])
        }

        let first = try run(["mkdir", "--parents", "ftp://testuser:testpass@127.0.0.1:2121\(folder)"])
        XCTAssertEqual(first.exitCode, 0, first.stderr)
        // Running it again against the same, now-existing path must still
        // succeed (mkdir -p semantics), not surface the "already exists"
        // server error as a failure.
        let second = try run(["mkdir", "--parents", "ftp://testuser:testpass@127.0.0.1:2121\(folder)"])
        XCTAssertEqual(second.exitCode, 0, second.stderr)
    }

    // MARK: - SSH keys

    private static let keys = "/tmp/teleport-it-keys"

    private func requireKeys() throws {
        try requireServers()
        guard FileManager.default.fileExists(atPath: Self.keys + "/ed25519") else {
            throw XCTSkip("Run scripts/start-test-servers.sh to generate the test keys")
        }
    }

    private func knownHostsFile() -> String {
        FileManager.default.temporaryDirectory
            .appending(component: "tport-it-known-hosts-\(UUID().uuidString).json").path
    }

    private func lsUpload(_ extra: [String], environment: [String: String] = [:]) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try run(["ls", "sftp://testuser@127.0.0.1:2222/upload",
                 "--known-hosts", knownHostsFile(), "--accept-new-hostkey",
                 "--no-ssh-config"] + extra,   // never the developer's own ~/.ssh/config
                environment: environment)
    }

    func test_identity_encrypted_readsPassphraseFromTheEnvironment() throws {
        try requireKeys()
        let result = try lsUpload(["--identity", Self.keys + "/ed25519_enc"],
                                  environment: ["TELEPORT_KEY_PASSPHRASE": "test-passphrase"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    func test_identity_encrypted_withNoPassphraseAndNoTerminal_failsSayingWhy() throws {
        try requireKeys()
        let result = try lsUpload(["--identity", Self.keys + "/ed25519_enc"])
        XCTAssertEqual(result.exitCode, 3, result.stderr)   // authFailed
        XCTAssertTrue(result.stderr.lowercased().contains("passphrase"), result.stderr)
    }

    /// Like `ssh`: with no key or password given, whatever ssh-agent holds is used.
    func test_agent_isUsedByDefault_andNoAgentTurnsItOff() throws {
        try requireKeys()
        let socket = "/tmp/tp-it-cli-agent-\(UUID().uuidString.prefix(8)).sock"
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        addTeardownBlock {
            agent.terminate()
            try? FileManager.default.removeItem(atPath: socket)
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socket), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        add.arguments = [Self.keys + "/ed25519"]
        add.environment = ["SSH_AUTH_SOCK": socket]
        add.standardOutput = FileHandle.nullDevice
        add.standardError = FileHandle.nullDevice
        try add.run()
        add.waitUntilExit()
        XCTAssertEqual(add.terminationStatus, 0)

        let withAgent = try lsUpload([], environment: ["SSH_AUTH_SOCK": socket])
        XCTAssertEqual(withAgent.exitCode, 0, withAgent.stderr)

        let without = try lsUpload(["--no-agent"], environment: ["SSH_AUTH_SOCK": socket])
        XCTAssertEqual(without.exitCode, 3, without.stderr)   // authFailed: nothing to offer
    }

    /// A host alias from an ssh config works the way it does for `ssh`:
    /// where to connect, who as, and which key all come from the file.
    func test_sshConfigAlias_suppliesHostPortUserAndIdentity() throws {
        try requireKeys()
        let config = FileManager.default.temporaryDirectory
            .appending(component: "tport-it-ssh-config-\(UUID().uuidString)")
        try """
        Host teleport-it
            HostName 127.0.0.1
            Port 2222
            User testuser
            IdentityFile \(Self.keys)/ed25519
        """.write(to: config, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: config) }

        let viaAlias = try run(["ls", "sftp://teleport-it/upload", "--ssh-config", config.path,
                                "--known-hosts", knownHostsFile(), "--accept-new-hostkey"])
        XCTAssertEqual(viaAlias.exitCode, 0, viaAlias.stderr)

        let ignoringConfig = try run(["ls", "sftp://teleport-it/upload", "--ssh-config", config.path, "--no-ssh-config",
                                      "--known-hosts", knownHostsFile(), "--accept-new-hostkey"])
        XCTAssertEqual(ignoringConfig.exitCode, 5, ignoringConfig.stderr)   // connectionFailed: no such host
    }

    /// A password given on the command line is used as given — a config
    /// `IdentityFile` must not replace it (a configured key means the
    /// password is never sent).
    func test_sshConfigIdentity_doesNotOverrideAnExplicitPassword() throws {
        try requireKeys()
        let config = FileManager.default.temporaryDirectory
            .appending(component: "tport-it-ssh-config-\(UUID().uuidString)")
        try "Host *\n  IdentityFile \(Self.keys)/unauthorised\n".write(to: config, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: config) }

        let result = try run(["ls", "sftp://testuser:testpass@127.0.0.1:2222/upload", "--ssh-config", config.path,
                              "--known-hosts", knownHostsFile(), "--accept-new-hostkey"])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }
}
