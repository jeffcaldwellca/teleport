import XCTest
import TeleportKit
@testable import Teleport

final class SSHConfigImportTests: XCTestCase {

    private var suiteName: String!
    private var store: ConnectionStore!

    override func setUp() {
        suiteName = "teleport-tests-\(UUID().uuidString)"
        store = ConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, secrets: MemorySecrets(),
                                forgetPassphrase: { _ in })
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func test_import_createsSFTPConnectionsNamedAfterTheAlias() {
        let added = store.importHosts([
            SSHConfig.Host(alias: "web", hostName: "web01.example.com", user: "deploy", port: 2202,
                           identityFile: "/Users/me/.ssh/deploy"),
        ], fileExists: { _ in true })

        XCTAssertEqual(added, 1)
        let connection = store.connections[0]
        XCTAssertEqual(connection.name, "web")
        XCTAssertEqual(connection.host, "web01.example.com")
        XCTAssertEqual(connection.port, 2202)
        XCTAssertEqual(connection.username, "deploy")
        XCTAssertEqual(connection.connectionProtocol, .sftp)
        XCTAssertEqual(connection.sshKeyPath, "/Users/me/.ssh/deploy")
    }

    /// `ssh` tries the agent before any IdentityFile. A config with
    /// `Host *` / `IdentityFile ~/.ssh/id_ed25519` (the usual macOS setup,
    /// with the passphrase in the agent) must not turn into a passphrase
    /// prompt on every imported host.
    func test_import_alwaysTurnsTheAgentOn_evenWithAnIdentityFile() {
        store.importHosts([
            SSHConfig.Host(alias: "web", hostName: "web01.example.com", identityFile: "/Users/me/.ssh/id_ed25519"),
        ], fileExists: { _ in true })

        XCTAssertTrue(store.connections[0].useSSHAgent)
        XCTAssertEqual(store.connections[0].sshKeyPath, "/Users/me/.ssh/id_ed25519")
    }

    /// An IdentityFile that isn't there (or still has unexpanded `%` tokens)
    /// would make the connection fail outright with nothing to fall back on.
    func test_import_identityFileThatDoesNotExist_isLeftOut() {
        store.importHosts([
            SSHConfig.Host(alias: "web", hostName: "web01.example.com", identityFile: "/Users/me/.ssh/%h_key"),
        ], fileExists: { _ in false })

        XCTAssertEqual(store.connections[0].sshKeyPath, "")
        XCTAssertTrue(store.connections[0].useSSHAgent)
    }

    /// No IdentityFile means `ssh` would be relying on the agent (or default
    /// keys); the imported connection does the same.
    func test_import_withoutAnIdentityFile_defaultsUserAndPort() {
        store.importHosts([SSHConfig.Host(alias: "db", hostName: "db.internal")])

        let connection = store.connections[0]
        XCTAssertTrue(connection.useSSHAgent)
        XCTAssertEqual(connection.sshKeyPath, "")
        XCTAssertEqual(connection.port, 22)
        XCTAssertEqual(connection.username, NSUserName())
    }

    func test_import_skipsHostsThatAreAlreadySaved_soImportingTwiceAddsNothing() {
        let hosts = [
            SSHConfig.Host(alias: "web", hostName: "web01.example.com", user: "deploy"),
            SSHConfig.Host(alias: "db", hostName: "db.internal"),
        ]
        XCTAssertEqual(store.importHosts(hosts), 2)
        XCTAssertEqual(store.importHosts(hosts), 0)
        XCTAssertEqual(store.connections.count, 2)
        XCTAssertTrue(store.isSaved(hosts[0]))
        XCTAssertFalse(store.isSaved(SSHConfig.Host(alias: "new", hostName: "new.example.com")))
    }

    func test_importedConnections_persist() {
        store.importHosts([SSHConfig.Host(alias: "web", hostName: "web01.example.com")])
        let reloaded = ConnectionStore(defaults: UserDefaults(suiteName: suiteName)!, secrets: MemorySecrets(),
                                       forgetPassphrase: { _ in })
        XCTAssertEqual(reloaded.connections.map(\.name), ["web"])
    }
}
