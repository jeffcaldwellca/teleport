import Foundation

public protocol RemoteClient: AnyObject, Sendable {
    /// Attempt to connect and authenticate.
    func connect() async throws

    /// Disconnect cleanly.
    func disconnect() async

    /// List the contents of a remote directory using its absolute path.
    func listDirectory(at absolutePath: String) async throws -> [FileItem]

    /// Download a remote file to a local URL, reporting progress (bytes, total).
    /// When `resume` is true and a partial local file exists, continue from its
    /// current size instead of restarting (falls back to a clean restart if the
    /// server can't resume).
    func download(
        remotePath: String,
        to localURL: URL,
        resume: Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws

    /// Upload a local file to a remote absolute path, reporting progress.
    /// When `resume` is true and a partial remote file exists, continue from its
    /// current size (falls back to a clean restart if the server can't resume).
    func upload(
        from localURL: URL,
        remotePath: String,
        resume: Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws

    /// Lightweight no-op to keep an idle connection from being dropped.
    func keepAlive() async

    /// Create a remote directory (and intermediate parents if possible).
    func createDirectory(at absolutePath: String) async throws

    /// Delete a remote file or directory.
    func delete(at absolutePath: String, isDirectory: Bool) async throws

    /// Rename / move a remote item.
    func rename(from: String, to: String) async throws

    /// Attempt to set UNIX permissions (octal). May throw `RemoteClientError.unsupported`.
    func setPermissions(_ octal: Int, at absolutePath: String) async throws

    /// Change ownership of a remote path. `owner` and `group` are name strings for FTP,
    /// numeric UID/GID strings for SFTP. Throws `RemoteClientError.unsupported` if unavailable.
    func setOwnership(owner: String, group: String, at absolutePath: String) async throws

    /// Returns the remote file's modification date, or nil if the path doesn't exist.
    func remoteModifiedDate(at remotePath: String) async -> Date?

    /// Best-effort: set the remote file's modification time (used after uploads
    /// so "overwrite if newer" comparisons stay meaningful). Servers without
    /// MFMT/SETSTAT support silently ignore this.
    func setModifiedDate(_ date: Date, at remotePath: String) async

    /// Returns true if the remote path exists (file or directory).
    func fileExists(at remotePath: String) async -> Bool
}

public enum RemoteClientError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case permissionDenied
    case fileNotFound(String)
    case transferFailed(String)
    case unsupported(String)
    case hostKeyUntrusted(host: String, port: Int, fingerprint: String)
    case hostKeyMismatch(host: String, port: Int, expected: String, actual: String)
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:           return "Not connected"
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .authenticationFailed:   return "Authentication failed"
        case .permissionDenied:       return "Permission denied"
        case .fileNotFound(let p):    return "File not found: \(p)"
        case .transferFailed(let m):  return "Transfer failed: \(m)"
        case .unsupported(let op):    return "\(op) is not supported by this server"
        case .hostKeyUntrusted(let host, let port, let fp):
            return "Host key for \(host):\(port) was not trusted (fingerprint \(SSHKeyFingerprint.display(fp))). " +
                   "Reconnect and choose to trust it if this is expected."
        case .hostKeyMismatch(let host, let port, let expected, let actual):
            return "Host key for \(host):\(port) has changed — possible MITM attack. " +
                   "Expected \(SSHKeyFingerprint.display(expected)), saw \(SSHKeyFingerprint.display(actual)). " +
                   "If this change is legitimate (e.g. the server was reinstalled), remove the stored host key and reconnect."
        case .unknown(let m):         return m
        }
    }
}
