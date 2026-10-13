import Foundation
import TeleportKit

/// Wires GUI-specific policy (sandbox-scoped key bookmarks, the host-key and
/// certificate confirmation sheet) into the clients' injectable dependencies. The CLI
/// has its own equivalent factory with stateless, non-interactive defaults.
enum RemoteClientFactory {
    /// A client for one transfer-queue worker: nothing else shares it, so FTP
    /// transfers can run on its own control connection.
    static func makeForTransfers(for connection: Connection, password: String) -> RemoteClient {
        make(for: connection, password: password, dedicatedToTransfers: true)
    }

    static func make(for connection: Connection, password: String) -> RemoteClient {
        make(for: connection, password: password, dedicatedToTransfers: false)
    }

    private static func make(
        for connection: Connection, password: String, dedicatedToTransfers: Bool
    ) -> RemoteClient {
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
            return FTPClient(
                connection: connection,
                password: password,
                certificateStore: .tlsCertificates,
                onUntrustedCertificate: { certificate in
                    await HostKeyConfirmation.shared.confirm(
                        host: certificate.host, port: certificate.port,
                        fingerprint: certificate.fingerprint,
                        certificateReason: certificate.reason
                    )
                },
                dedicatedToTransfers: dedicatedToTransfers
            )
        }
    }
}
