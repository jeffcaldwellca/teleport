import Foundation

public struct Connection: Identifiable, Codable, Hashable {
    public var id: UUID = UUID()
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var connectionProtocol: ConnectionProtocol
    public var initialPath: String = "/"
    public var sshKeyPath: String = ""
    public var notes: String = ""
    public var createdAt: Date = Date()

    public enum ConnectionProtocol: String, Codable, CaseIterable, Identifiable {
        case ftp  = "FTP"
        case ftps = "FTPS"
        case sftp = "SFTP"

        public var id: String { rawValue }

        public var defaultPort: Int {
            switch self {
            case .ftp:  return 21
            case .ftps: return 21
            case .sftp: return 22
            }
        }

        public var systemImage: String {
            switch self {
            case .ftp:  return "network"
            case .ftps: return "lock.shield"
            case .sftp: return "key.horizontal"
            }
        }
    }

    public init(
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

    public var displayTitle: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    public var displaySubtitle: String {
        "\(connectionProtocol.rawValue) · \(host):\(port)"
    }
}
