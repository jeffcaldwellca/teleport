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

    /// `tport` built from this checkout, so the tests exercise the code as it
    /// is now rather than whatever binary was left in `.build` (a stale one
    /// once reported the previous version right after a bump). `swift build`
    /// is incremental: a few seconds when nothing has changed. Built once per
    /// test process.
    private static let builtTport: Result<URL, Error> = {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TeleportTests/
            .deletingLastPathComponent()  // repo root
            .appending(path: "TeleportKit")
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.arguments = ["swift", "build", "--product", "tport", "--package-path", package.path]
        let output = Pipe()
        build.standardOutput = output
        build.standardError = output
        do {
            try build.run()
            // Drain before waiting, or a chatty build fills the pipe and stalls.
            let log = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            build.waitUntilExit()
            guard build.terminationStatus == 0 else { return .failure(TportBuildFailed(log: log)) }
            return .success(package.appending(path: ".build/debug/tport"))
        } catch {
            return .failure(error)
        }
    }()

    private struct TportBuildFailed: Error, CustomStringConvertible {
        let log: String
        var description: String { "Building tport failed:\n" + log.suffix(3000) }
    }

    private func tportBinaryURL() throws -> URL {
        try Self.builtTport.get()
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

    /// Reading the ssh config can send a URL somewhere other than its host
    /// reads. When that connection then fails, the error has to say where it
    /// really went and how to switch the lookup off.
    func test_sshConfigAlias_failure_saysWhichConfigEntryWasUsed() throws {
        try requireKeys()
        let config = FileManager.default.temporaryDirectory
            .appending(component: "tport-it-ssh-config-\(UUID().uuidString)")
        try "Host teleport-it\n  HostName 127.0.0.1\n  Port 2222\n  User testuser\n"
            .write(to: config, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: config) }

        // No --accept-new-hostkey: fails closed on the unknown host key.
        let result = try run(["ls", "sftp://teleport-it/upload", "--ssh-config", config.path,
                              "--known-hosts", knownHostsFile(), "--no-agent"])
        XCTAssertEqual(result.exitCode, 6, result.stderr)   // hostKey
        XCTAssertTrue(result.stderr.contains("teleport-it"), result.stderr)
        XCTAssertTrue(result.stderr.contains("testuser@127.0.0.1:2222"), result.stderr)
        XCTAssertTrue(result.stderr.contains("--no-ssh-config"), result.stderr)
    }

    // MARK: - sync

    private struct SyncFixture {
        let local: URL
        let remoteURL: String
        let options: [String]
    }

    /// A small local site and a fresh remote folder on the SFTP or FTP server.
    private func syncFixture(ftp: Bool = false) throws -> SyncFixture {
        let local = FileManager.default.temporaryDirectory.appending(component: "tport-it-sync-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: local) }
        for (path, contents) in [("index.html", "<h1>hello</h1>"), ("css/site.css", "body{}"), ("js/app.js", "run()")] {
            let url = local.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        let name = "sync-\(UUID().uuidString)"
        if ftp {
            return SyncFixture(local: local, remoteURL: "ftp://testuser:testpass@127.0.0.1:2121/ftp/testuser/\(name)", options: [])
        }
        return SyncFixture(local: local, remoteURL: "sftp://testuser:testpass@127.0.0.1:2222/upload/\(name)",
                           options: ["--known-hosts", knownHostsFile(), "--accept-new-hostkey", "--no-ssh-config"])
    }

    private func sync(_ fixture: SyncFixture, _ extra: [String] = [], local: URL? = nil) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try run(["sync", (local ?? fixture.local).path, fixture.remoteURL] + fixture.options + extra)
    }

    private func lines(_ output: String, starting prefix: String) -> [String] {
        output.split(separator: "\n").map(String.init).filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// On both servers — the FTP one only lists times to the minute, which is
    /// exactly where a naive comparison re-uploads everything every time.
    func test_sync_uploadsEverythingOnce_thenOnlyWhatChanged() throws {
        try requireServers()
        for ftp in [false, true] {
            let fixture = try syncFixture(ftp: ftp)

            let first = try sync(fixture)
            XCTAssertEqual(first.exitCode, 0, first.stderr)
            XCTAssertEqual(lines(first.stdout, starting: "upload "),
                           ["upload css/site.css", "upload index.html", "upload js/app.js"], "ftp: \(ftp)")

            let second = try sync(fixture)
            XCTAssertEqual(second.exitCode, 0, second.stderr)
            XCTAssertEqual(lines(second.stdout, starting: "upload "), [], "ftp: \(ftp) — \(second.stdout)")
            XCTAssertTrue(second.stdout.contains("Already in sync"), second.stdout)

            try Data("body{color:red}".utf8).write(to: fixture.local.appending(path: "css/site.css"))
            let third = try sync(fixture)
            XCTAssertEqual(lines(third.stdout, starting: "upload "), ["upload css/site.css"], "ftp: \(ftp)")
        }
    }

    func test_sync_dryRun_changesNothing() throws {
        try requireServers()
        let fixture = try syncFixture()

        let dry = try sync(fixture, ["--dry-run"])
        XCTAssertEqual(dry.exitCode, 0, dry.stderr)
        XCTAssertEqual(lines(dry.stdout, starting: "upload ").count, 3)
        XCTAssertTrue(dry.stdout.contains("Nothing was changed"), dry.stdout)

        // Had the dry run uploaded anything, this run would find it in place.
        let real = try sync(fixture)
        XCTAssertEqual(lines(real.stdout, starting: "upload ").count, 3)
    }

    func test_sync_delete_removesWhatIsNoLongerInTheSource_andOnlyWhenAsked() throws {
        try requireServers()
        let fixture = try syncFixture()
        XCTAssertEqual(try sync(fixture).exitCode, 0)
        try FileManager.default.removeItem(at: fixture.local.appending(path: "js"))

        let keeping = try sync(fixture)
        XCTAssertEqual(lines(keeping.stdout, starting: "delete "), [])

        let deleting = try sync(fixture, ["--delete"])
        XCTAssertEqual(deleting.exitCode, 0, deleting.stderr)
        XCTAssertEqual(lines(deleting.stdout, starting: "delete "), ["delete js", "delete js/app.js"])

        let after = try sync(fixture, ["--delete"])
        XCTAssertTrue(after.stdout.contains("Already in sync"), after.stdout)
    }

    func test_sync_down_bringsALocalFolderUpToDate() throws {
        try requireServers()
        let fixture = try syncFixture()
        XCTAssertEqual(try sync(fixture).exitCode, 0)
        let copy = FileManager.default.temporaryDirectory.appending(component: "tport-it-sync-down-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }

        let down = try sync(fixture, ["--direction", "down"], local: copy)
        XCTAssertEqual(down.exitCode, 0, down.stderr)
        XCTAssertEqual(lines(down.stdout, starting: "download ").count, 3)
        for path in ["index.html", "css/site.css", "js/app.js"] {
            XCTAssertEqual(try Data(contentsOf: copy.appending(path: path)),
                           try Data(contentsOf: fixture.local.appending(path: path)), path)
        }

        let again = try sync(fixture, ["--direction", "down"], local: copy)
        XCTAssertTrue(again.stdout.contains("Already in sync"), again.stdout)
    }

    /// A mistyped or unmounted source must not empty the server.
    func test_sync_emptyOrMissingSource_withDelete_isRefused_andDeletesNothing() throws {
        try requireServers()
        let fixture = try syncFixture()
        XCTAssertEqual(try sync(fixture).exitCode, 0)
        let empty = FileManager.default.temporaryDirectory.appending(component: "tport-it-sync-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: empty) }

        let refused = try sync(fixture, ["--delete"], local: empty)
        XCTAssertNotEqual(refused.exitCode, 0)
        XCTAssertTrue(refused.stderr.lowercased().contains("empty"), refused.stderr)

        let missing = try sync(fixture, ["--delete"], local: empty.appending(path: "not-here"))
        XCTAssertNotEqual(missing.exitCode, 0)
        XCTAssertTrue(missing.stderr.contains("doesn\u{2019}t exist") || missing.stderr.contains("doesn't exist"), missing.stderr)

        // Everything is still on the server.
        XCTAssertTrue(try sync(fixture).stdout.contains("Already in sync"))
    }

    /// One file can't be read. Everything else is still transferred — but
    /// with part of the sync having failed, nothing is deleted: the
    /// destination must not be left with neither the old nor the new.
    func test_sync_afterAFailedFile_transfersTheRest_butDeletesNothing() throws {
        try requireServers()
        let fixture = try syncFixture()
        XCTAssertEqual(try sync(fixture).exitCode, 0)

        // Rename index.html → home.html locally, and make the new file unreadable.
        let renamed = fixture.local.appending(path: "home.html")
        try FileManager.default.moveItem(at: fixture.local.appending(path: "index.html"), to: renamed)
        try Data("new page".utf8).write(to: fixture.local.appending(path: "about.html"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: renamed.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: renamed.path) }

        let result = try sync(fixture, ["--delete"])

        XCTAssertEqual(result.exitCode, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("failed: upload home.html"), result.stderr)
        XCTAssertEqual(lines(result.stdout, starting: "upload "), ["upload about.html"])
        XCTAssertEqual(lines(result.stdout, starting: "delete "), [], "index.html must survive: its replacement never arrived")
        XCTAssertTrue(result.stderr.lowercased().contains("nothing was deleted"), result.stderr)

        // Once the file can be read, the same command finishes the job.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: renamed.path)
        let retry = try sync(fixture, ["--delete"])
        XCTAssertEqual(retry.exitCode, 0, retry.stderr)
        XCTAssertEqual(lines(retry.stdout, starting: "upload "), ["upload home.html"])
        XCTAssertEqual(lines(retry.stdout, starting: "delete "), ["delete index.html"])
    }

    /// A change that leaves the size the same is only visible in the times —
    /// on the FTP server that means past a listing that is to the minute and
    /// in the server's time zone.
    func test_sync_noticesASameSizeEdit_onBothServers() throws {
        try requireServers()
        for ftp in [false, true] {
            let fixture = try syncFixture(ftp: ftp)
            XCTAssertEqual(try sync(fixture).exitCode, 0)
            XCTAssertTrue(try sync(fixture).stdout.contains("Already in sync"), "ftp: \(ftp)")

            let page = fixture.local.appending(path: "index.html")
            let original = try Data(contentsOf: page)
            try Data(String(repeating: "x", count: original.count).utf8).write(to: page)
            // Clearly later than the upload, whatever the clocks are doing.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: page.path)

            let result = try sync(fixture)
            XCTAssertEqual(lines(result.stdout, starting: "upload "), ["upload index.html"], "ftp: \(ftp) — \(result.stdout)")
        }
    }

    // MARK: - Version and trust management (no servers needed)

    func test_version_isTheAppsVersion() throws {
        let projectFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "project.yml")
        let project = try String(contentsOf: projectFile, encoding: .utf8)
        let line = try XCTUnwrap(project.split(separator: "\n").first { $0.contains("MARKETING_VERSION:") })
        let expected = line.split(separator: ":")[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))

        let result = try run(["--version"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), expected)
    }

    private func trustFile(_ entries: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(component: "tport-it-trust-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let body = entries.map { "\"\($0)\": {\"fingerprint\": \"SHA256:\(String(repeating: "ab", count: 32))\", \"firstSeen\": \"2026-10-12T00:00:00Z\"}" }
        try "{\"schemaVersion\": 1, \"entries\": {\(body.joined(separator: ", "))}}".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// The errors tell people to "remove the stored host key"; there has to
    /// be a way to do that other than editing a JSON file.
    func test_trust_listsAndForgetsHostKeysAndCertificates() throws {
        let hosts = try trustFile(["web.example.com:22", "web.example.com:2222", "db.example.com:22"])
        let certs = try trustFile(["ftp.example.com:21"])
        let stores = ["--known-hosts", hosts, "--trusted-certs", certs]

        let listed = try run(["trust", "list"] + stores)
        XCTAssertEqual(listed.exitCode, 0, listed.stderr)
        for expected in ["web.example.com:22", "web.example.com:2222", "db.example.com:22", "ftp.example.com:21"] {
            XCTAssertTrue(listed.stdout.contains(expected), "\(expected) missing from: \(listed.stdout)")
        }

        // host:port forgets exactly that one…
        XCTAssertEqual(try run(["trust", "forget", "web.example.com:2222"] + stores).exitCode, 0)
        var remaining = try run(["trust", "list"] + stores).stdout
        XCTAssertFalse(remaining.contains("web.example.com:2222"))
        XCTAssertTrue(remaining.contains("web.example.com:22"))

        // …a bare host forgets every entry for it, in both stores.
        XCTAssertEqual(try run(["trust", "forget", "ftp.example.com"] + stores).exitCode, 0)
        XCTAssertEqual(try run(["trust", "forget", "web.example.com"] + stores).exitCode, 0)
        remaining = try run(["trust", "list"] + stores).stdout
        XCTAssertFalse(remaining.contains("web.example.com"))
        XCTAssertFalse(remaining.contains("ftp.example.com"))
        XCTAssertTrue(remaining.contains("db.example.com:22"))

        let unknown = try run(["trust", "forget", "nowhere.example.com"] + stores)
        XCTAssertNotEqual(unknown.exitCode, 0)
        XCTAssertTrue(unknown.stderr.contains("nowhere.example.com"), unknown.stderr)
    }

    // MARK: - Modification times and JSON

    /// `put` and `get` keep the file's modification time, as the app and
    /// `sync` do — otherwise every later "is it newer?" comparison is wrong.
    func test_putAndGet_preserveModificationTimes() throws {
        try requireServers()
        let dir = FileManager.default.temporaryDirectory.appending(component: "tport-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appending(component: "dated.txt")
        try "contents".write(to: original, atomically: true, encoding: .utf8)
        let lastYear = Date(timeIntervalSince1970: 1_750_000_000)
        try FileManager.default.setAttributes([.modificationDate: lastYear], ofItemAtPath: original.path)

        let remote = "sftp://testuser:testpass@127.0.0.1:2222/upload/dated-\(UUID().uuidString).txt"
        let options = ["--known-hosts", knownHostsFile(), "--accept-new-hostkey", "--no-ssh-config"]
        XCTAssertEqual(try run(["put", original.path, remote] + options).exitCode, 0)

        let copy = dir.appending(component: "copy.txt")
        let get = try run(["get", remote, copy.path] + options)
        XCTAssertEqual(get.exitCode, 0, get.stderr)

        let modified = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, lastYear.timeIntervalSince1970, accuracy: 2)
    }

    func test_sync_json_reportsThePlanInAMachineReadableForm() throws {
        try requireServers()
        let fixture = try syncFixture()

        let result = try sync(fixture, ["--dry-run", "--json"])

        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let report = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(report["direction"] as? String, "up")
        XCTAssertEqual(report["dryRun"] as? Bool, true)
        let actions = try XCTUnwrap(report["actions"] as? [[String: Any]])
        let uploads = actions.filter { $0["action"] as? String == "upload" }
        XCTAssertEqual(Set(uploads.compactMap { $0["path"] as? String }), ["index.html", "css/site.css", "js/app.js"])
        XCTAssertTrue(uploads.allSatisfy { $0["status"] as? String == "planned" })
    }
}
