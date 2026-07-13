import Foundation
import TeleportKit

/// Wires GUI-specific policy (sandbox-scoped key bookmarks, the host-key
/// confirmation sheet) into `SFTPClient`'s injectable dependencies. The CLI
/// has its own equivalent factory with stateless, non-interactive defaults.
enum RemoteClientFactory {
    static func make(for connection: Connection, password: String) -> RemoteClient {
        switch connection.connectionProtocol {
        case .sftp:
            return SFTPClient(
                connection: connection,
                password: password,
                hostKeyStore: .shared,
                keyReader: { url in
                    if let data = await MainActor.run(body: {
                        try? BookmarkStore.shared.withAccess(
                            name: BookmarkStore.sshKeyName(for: connection.id)
                        ) { try Data(contentsOf: $0) }
                    }) ?? nil {
                        return data
                    }
                    do {
                        return try Data(contentsOf: url)
                    } catch {
                        throw RemoteClientError.unknown(
                            "Could not read SSH key at \(url.path): \(error.localizedDescription). " +
                            "Try selecting the key again from the connection editor so the app can store a sandbox-friendly bookmark."
                        )
                    }
                },
                onUnknownHostKey: { host, port, fingerprint in
                    await HostKeyConfirmation.shared.confirm(host: host, port: port, fingerprint: fingerprint)
                }
            )
        case .ftp, .ftps:
            return FTPClient(connection: connection, password: password)
        }
    }
}
