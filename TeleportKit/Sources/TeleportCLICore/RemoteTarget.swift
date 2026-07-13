import Foundation
import TeleportKit

public struct RemoteTarget {
    public let connectionProtocol: Connection.ConnectionProtocol
    public let username: String
    public let host: String
    public let port: Int
    public let path: String

    public static func parse(_ raw: String) throws -> RemoteTarget {
        guard let components = URLComponents(string: raw), let scheme = components.scheme else {
            throw TportUsageError.invalidURL(raw)
        }
        let proto: Connection.ConnectionProtocol
        switch scheme.lowercased() {
        case "sftp": proto = .sftp
        case "ftp":  proto = .ftp
        case "ftps": proto = .ftps
        default:
            throw TportUsageError.invalidURL("Unsupported scheme '\(scheme)' — use sftp://, ftp://, or ftps://")
        }
        guard let host = components.host, !host.isEmpty else {
            throw TportUsageError.invalidURL(raw)
        }
        let username = components.user ?? NSUserName()
        let port = components.port ?? proto.defaultPort
        let path = components.path.isEmpty ? "/" : components.path
        return RemoteTarget(connectionProtocol: proto, username: username, host: host, port: port, path: path)
    }

    public func makeConnection() -> Connection {
        Connection(
            name: "\(username)@\(host)",
            host: host,
            port: port,
            username: username,
            connectionProtocol: connectionProtocol
        )
    }
}

public enum TportUsageError: LocalizedError, CustomStringConvertible {
    case invalidURL(String)
    case missingCredentials(String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .invalidURL(let raw):
            return "Not a valid sftp://, ftp://, or ftps:// URL: \(raw)"
        case .missingCredentials(let detail):
            return detail
        }
    }
}
