import Foundation

struct Connection: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int
    var username: String
    var connectionProtocol: ConnectionProtocol
    var initialPath: String = "/"
    var sshKeyPath: String = ""
    var notes: String = ""
    var createdAt: Date = Date()

    enum ConnectionProtocol: String, Codable, CaseIterable, Identifiable {
        case ftp  = "FTP"
        case ftps = "FTPS"
        case sftp = "SFTP"

        var id: String { rawValue }

        var defaultPort: Int {
            switch self {
            case .ftp:  return 21
            case .ftps: return 21
            case .sftp: return 22
            }
        }

        var systemImage: String {
            switch self {
            case .ftp:  return "network"
            case .ftps: return "lock.shield"
            case .sftp: return "key.horizontal"
            }
        }
    }

    init(
        name: String = "",
        host: String = "",
        port: Int? = nil,
        username: String = "anonymous",
        connectionProtocol: ConnectionProtocol = .sftp,
        initialPath: String = "/",
        sshKeyPath: String = "",
        notes: String = ""
    ) {
        self.name               = name
        self.host               = host
        self.connectionProtocol = connectionProtocol
        self.port               = port ?? connectionProtocol.defaultPort
        self.username           = username
        self.initialPath        = initialPath
        self.sshKeyPath         = sshKeyPath
        self.notes              = notes
    }

    var displayTitle: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    var displaySubtitle: String {
        "\(connectionProtocol.rawValue) · \(host):\(port)"
    }
}
