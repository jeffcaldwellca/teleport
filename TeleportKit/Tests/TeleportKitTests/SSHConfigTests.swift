import XCTest
import TeleportKit

final class SSHConfigTests: XCTestCase {

    private let home = "/Users/tester"
    private func config(_ text: String) -> SSHConfig { SSHConfig(text: text, homeDirectory: home) }

    func test_resolve_readsHostNameUserPortAndIdentityFile() {
        let host = config("""
        Host web
            HostName web01.example.com
            User deploy
            Port 2202
            IdentityFile ~/.ssh/deploy_ed25519
        """).resolve("web")

        XCTAssertEqual(host, SSHConfig.Host(
            alias: "web", hostName: "web01.example.com", user: "deploy", port: 2202,
            identityFile: "/Users/tester/.ssh/deploy_ed25519"
        ))
    }

    func test_aliasWithoutHostName_usesTheAliasItself() {
        let host = config("Host build.example.com\n  User ci").resolve("build.example.com")
        XCTAssertEqual(host.hostName, "build.example.com")
        XCTAssertEqual(host.user, "ci")
    }

    func test_firstValueWins_asInOpenSSH() {
        let host = config("""
        Host web
            User first
        Host web
            User second
            Port 2202
        """).resolve("web")

        XCTAssertEqual(host.user, "first")
        XCTAssertEqual(host.port, 2202)
    }

    func test_wildcardBlocksSupplyDefaults_withoutOverridingSpecificOnes() {
        let text = """
        Host db
            User postgres
        Host *.example.com db
            Port 2222
        Host *
            User everyone
            IdentityFile ~/.ssh/id_ed25519
        """
        let db = config(text).resolve("db")
        XCTAssertEqual(db.user, "postgres")
        XCTAssertEqual(db.port, 2222)
        XCTAssertEqual(db.identityFile, "/Users/tester/.ssh/id_ed25519")

        let other = config(text).resolve("mail.example.com")
        XCTAssertEqual(other.user, "everyone")
        XCTAssertEqual(other.port, 2222)

        let unrelated = config(text).resolve("elsewhere.org")
        XCTAssertEqual(unrelated.hostName, "elsewhere.org")
        XCTAssertNil(unrelated.port)
    }

    func test_negatedPatternExcludesAHostFromItsBlock() {
        let text = """
        Host *.example.com !legacy.example.com
            User modern
        """
        XCTAssertEqual(config(text).resolve("app.example.com").user, "modern")
        XCTAssertNil(config(text).resolve("legacy.example.com").user)
    }

    func test_hosts_listsConcreteAliasesOnly_inFileOrder_withDefaultsApplied() {
        let hosts = config("""
        Host *
            User everyone
        Host web staging-?
            HostName 10.0.0.5
        Host db !old
            User postgres
        Host web
            Port 22
        """).hosts

        XCTAssertEqual(hosts.map(\.alias), ["web", "db"])
        XCTAssertEqual(hosts.map(\.hostName), ["10.0.0.5", "db"])
        XCTAssertEqual(hosts.map(\.user), ["everyone", "everyone"])
    }

    func test_identityFile_expandsTildeAndHomeToken() {
        XCTAssertEqual(config("Host a\n IdentityFile ~/keys/a").resolve("a").identityFile, "/Users/tester/keys/a")
        XCTAssertEqual(config("Host a\n IdentityFile %d/keys/a").resolve("a").identityFile, "/Users/tester/keys/a")
        XCTAssertEqual(config("Host a\n IdentityFile /abs/key").resolve("a").identityFile, "/abs/key")
    }

    /// Real config files are full of things this parser has no use for.
    /// None of them may throw, crash, or bleed into the next host.
    func test_unknownDirectivesQuotesEqualsCommentsAndCase_areTolerated() {
        let host = config("""
        # global comment
        Include ~/.ssh/config.d/*
        ServerAliveInterval 60

        HOST "quoted alias"   web   # trailing comment
            hostname = web01.example.com
            USER="deploy user"
            Port=notanumber
            KexAlgorithms +diffie-hellman-group14-sha1
            SetEnv TERM=xterm-256color
            ProxyJump bastion
        Match host *.internal exec "true"
            User matched
        Host other
            User someone
        """)

        let web = host.resolve("web")
        XCTAssertEqual(web.hostName, "web01.example.com")
        XCTAssertEqual(web.user, "deploy user")
        XCTAssertNil(web.port)
        XCTAssertEqual(host.resolve("quoted alias").hostName, "web01.example.com")
        XCTAssertEqual(host.resolve("other").user, "someone")
        XCTAssertNil(host.resolve("box.internal").user, "Match blocks are skipped, not applied to everything")
        XCTAssertEqual(host.hosts.map(\.alias), ["quoted alias", "web", "other"])
    }

    func test_emptyOrMissingConfig_resolvesToTheNameItself() {
        XCTAssertEqual(config("").resolve("example.com"),
                       SSHConfig.Host(alias: "example.com", hostName: "example.com"))
        XCTAssertTrue(SSHConfig.load(from: URL(fileURLWithPath: "/nonexistent/ssh_config")).hosts.isEmpty)
    }
}
