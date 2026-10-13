import Foundation
import TeleportKit

@Observable
final class ConnectionStore {
    private let defaultsKey = "com.teleport.connections"
    private(set) var connections: [Connection] = []
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Import from ~/.ssh/config

    /// Whether a connection to the same place as `host` (address, port, user)
    /// already exists.
    func isSaved(_ host: SSHConfig.Host) -> Bool {
        let candidate = Self.connection(for: host)
        return connections.contains {
            $0.connectionProtocol == .sftp && $0.host.lowercased() == candidate.host.lowercased()
                && $0.port == candidate.port && $0.username == candidate.username
        }
    }

    /// Add an SFTP connection for each host not already saved. Returns how
    /// many were added.
    @discardableResult
    func importHosts(
        _ hosts: [SSHConfig.Host],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Int {
        var added = 0
        for host in hosts where !isSaved(host) {
            var connection = Self.connection(for: host)
            // A key file that isn't there would fail the connection outright.
            if !fileExists(connection.sshKeyPath) { connection.sshKeyPath = "" }
            connections.append(connection)
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    private static func connection(for host: SSHConfig.Host) -> Connection {
        var connection = Connection(
            name: host.alias,
            host: host.hostName,
            port: host.port,
            username: host.user ?? NSUserName(),
            connectionProtocol: .sftp,
            sshKeyPath: host.identityFile ?? ""
        )
        // ssh tries the agent before any IdentityFile, and on macOS the key's
        // passphrase usually lives there — so the agent is on either way.
        connection.useSSHAgent = true
        return connection
    }

    func add(_ connection: Connection, password: String) throws {
        try KeychainService.save(password: password, for: connection.id)
        connections.append(connection)
        persist()
    }

    func update(_ connection: Connection, password: String?) throws {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        if let password = password {
            try KeychainService.save(password: password, for: connection.id)
        }
        connections[index] = connection
        persist()
    }

    @MainActor
    func delete(_ connection: Connection) {
        KeychainService.delete(for: connection.id)
        PassphrasePrompt.shared.forget(connection.id)
        connections.removeAll { $0.id == connection.id }
        persist()
    }

    func password(for connection: Connection) -> String {
        (try? KeychainService.load(for: connection.id)) ?? ""
    }

    func move(from source: IndexSet, to destination: Int) {
        connections.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Connection].self, from: data) else { return }
        connections = decoded
    }
}
