import Foundation

@Observable
final class ConnectionStore {
    private let defaultsKey = "com.teleport.connections"
    private(set) var connections: [Connection] = []

    init() {
        load()
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

    func delete(_ connection: Connection) {
        KeychainService.delete(for: connection.id)
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
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Connection].self, from: data) else { return }
        connections = decoded
    }
}
