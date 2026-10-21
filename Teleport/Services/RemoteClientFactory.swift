import Foundation
import TeleportKit

/// Wires GUI-specific policy (bookmarked key files, the host-key and
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
            // What this client was last given, so that if it comes back
            // saying "that didn't work" the prompt knows which one failed.
            let lastPassphrase = LastPassphrase()
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
                            "Check that the file exists and is readable, or choose the key again in the connection editor."
                        )
                    }
                },
                onUnknownHostKey: { host, port, fingerprint in
                    await HostKeyConfirmation.shared.confirm(host: host, port: port, fingerprint: fingerprint)
                },
                passphraseProvider: { keyPath, retry in
                    let answer = await PassphrasePrompt.shared.passphrase(
                        for: connection.id, keyPath: keyPath, rejected: retry ? lastPassphrase.value : nil
                    )
                    lastPassphrase.value = answer
                    return answer
                },
                interactivePromptProvider: { challenge in
                    await InteractivePrompt.shared.answer(for: connection.name, challenge: challenge)
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

private final class LastPassphrase: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
