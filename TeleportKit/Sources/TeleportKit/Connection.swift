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
    /// SFTP only: offer keys held by ssh-agent before the key file / password.
    public var useSSHAgent: Bool = false
    /// FTPS only: TLS from the first byte (implicit FTPS) rather than
    /// upgrading with AUTH TLS (explicit). Usually on port 990, but not always.
    public var implicitTLS: Bool = false

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
        notes: String = "",
        implicitTLS: Bool? = nil
    ) {
        self.name               = name
        self.host               = host
        self.connectionProtocol = connectionProtocol
        self.port               = port ?? connectionProtocol.defaultPort
        self.username           = username
        self.initialPath        = initialPath
        self.sshKeyPath         = sshKeyPath
        self.notes              = notes
        // Port 990 is implicit FTPS's own port, and what used to select it.
        self.implicitTLS        = implicitTLS ?? (connectionProtocol == .ftps && self.port == 990)
    }

    /// Hand-written so connections saved before a property existed still
    /// load: anything added after 1.0 is read with a fallback.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try container.decode(UUID.self, forKey: .id)
        name               = try container.decode(String.self, forKey: .name)
        host               = try container.decode(String.self, forKey: .host)
        port               = try container.decode(Int.self, forKey: .port)
        username           = try container.decode(String.self, forKey: .username)
        connectionProtocol = try container.decode(ConnectionProtocol.self, forKey: .connectionProtocol)
        initialPath        = try container.decode(String.self, forKey: .initialPath)
        sshKeyPath         = try container.decode(String.self, forKey: .sshKeyPath)
        notes              = try container.decode(String.self, forKey: .notes)
        createdAt          = try container.decode(Date.self, forKey: .createdAt)
        useSSHAgent        = try container.decodeIfPresent(Bool.self, forKey: .useSSHAgent) ?? false
        // Saved before the setting existed: port 990 was what meant implicit.
        implicitTLS        = try container.decodeIfPresent(Bool.self, forKey: .implicitTLS)
                             ?? (connectionProtocol == .ftps && port == 990)
    }

    public var displayTitle: String {
        name.isEmpty ? "\(username)@\(host)" : name
    }

    public var displaySubtitle: String {
        "\(connectionProtocol.rawValue) · \(host):\(port)"
    }
}
