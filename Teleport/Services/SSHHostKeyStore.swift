import Foundation
import CryptoKit
import NIOCore
import NIOSSH
import Citadel

/// Persistent record of trusted SSH host keys, keyed by `host:port`.
/// Stored as JSON under `Application Support/Teleport/known_hosts.json`.
actor SSHHostKeyStore {

    static let shared = SSHHostKeyStore()

    private struct Entry: Codable {
        var fingerprint: String   // "SHA256:<hex>"
        var firstSeen: Date
    }

    private struct File: Codable {
        var schemaVersion: Int = 1
        var entries: [String: Entry] = [:]
    }

    private var file: File?
    private var loaded = false

    /// Returns the stored fingerprint for `host:port`, or `nil` if none.
    func fingerprint(for host: String, port: Int) -> String? {
        ensureLoaded()
        return file?.entries[Self.key(host: host, port: port)]?.fingerprint
    }

    /// Records `fingerprint` as trusted for `host:port`. Overwrites any prior entry.
    func record(host: String, port: Int, fingerprint: String) throws {
        ensureLoaded()
        if file == nil { file = File() }
        file?.entries[Self.key(host: host, port: port)] = Entry(
            fingerprint: fingerprint, firstSeen: Date()
        )
        try persist()
    }

    /// Forgets the stored entry for `host:port`, if any.
    func forget(host: String, port: Int) throws {
        ensureLoaded()
        file?.entries.removeValue(forKey: Self.key(host: host, port: port))
        try persist()
    }

    /// Forgets the entry identified by its `"host:port"` key.
    func forget(id: String) throws {
        ensureLoaded()
        file?.entries.removeValue(forKey: id)
        try persist()
    }

    /// Forgets every trusted host key.
    func forgetAll() throws {
        ensureLoaded()
        file?.entries.removeAll()
        try persist()
    }

    /// A trusted host, for display/management in Settings.
    struct TrustedHost: Identifiable, Sendable {
        let id: String          // "host:port"
        let host: String
        let port: Int
        let fingerprint: String
        let firstSeen: Date
    }

    /// All trusted host keys, sorted by host.
    func trustedHosts() -> [TrustedHost] {
        ensureLoaded()
        let entries = file?.entries ?? [:]
        return entries.map { key, entry in
            // Split "host:port" on the last colon (hosts won't contain one).
            if let colon = key.lastIndex(of: ":"), let port = Int(key[key.index(after: colon)...]) {
                return TrustedHost(id: key, host: String(key[..<colon]), port: port,
                                   fingerprint: entry.fingerprint, firstSeen: entry.firstSeen)
            }
            return TrustedHost(id: key, host: key, port: 0,
                               fingerprint: entry.fingerprint, firstSeen: entry.firstSeen)
        }
        .sorted { ($0.host, $0.port) < ($1.host, $1.port) }
    }

    // MARK: - Storage

    private static func key(host: String, port: Int) -> String { "\(host):\(port)" }

    private static var storeURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = support.appending(component: "Teleport")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(component: "known_hosts.json")
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.storeURL,
              let data = try? Data(contentsOf: url) else {
            file = File()
            return
        }
        if let decoded = try? JSONDecoder().decode(File.self, from: data) {
            file = decoded
        } else {
            file = File()
        }
    }

    private func persist() throws {
        guard let file = file, let url = Self.storeURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: url, options: [.atomic])
    }
}

// MARK: - Fingerprint helpers

enum SSHKeyFingerprint {
    /// Compute the OpenSSH-style SHA256 fingerprint for a public key.
    static func sha256(of key: NIOSSHPublicKey) -> String {
        var buf = ByteBufferAllocator().buffer(capacity: 256)
        _ = key.write(to: &buf)
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        let digest = SHA256.hash(data: Data(bytes))
        return "SHA256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Friendlier display: groups of two hex digits separated by colons.
    static func display(_ fingerprint: String) -> String {
        guard fingerprint.hasPrefix("SHA256:") else { return fingerprint }
        let hex = String(fingerprint.dropFirst("SHA256:".count))
        var pairs: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            pairs.append(String(hex[i..<j]))
            i = j
        }
        return "SHA256:" + pairs.joined(separator: ":")
    }
}

// MARK: - Validator

/// `NIOSSHClientServerAuthenticationDelegate` that:
///   * captures the server's host-key fingerprint synchronously, and
///   * fails the handshake if a previously-trusted fingerprint doesn't match.
///
/// First-use confirmation is *not* done here — that requires UI and is handled
/// in `SFTPClient.connect`, which runs a one-shot connection with `expected = nil`
/// to capture the fingerprint, then prompts the user before recording it.
final class CapturingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {

    /// Set when constructed for a known-host connection. Mismatch → handshake fails.
    let expected: String?

    private let lock = NSLock()
    private var _captured: String?

    init(expected: String? = nil) {
        self.expected = expected
    }

    /// Fingerprint captured during the handshake (if any).
    var captured: String? {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = SSHKeyFingerprint.sha256(of: hostKey)
        lock.lock()
        _captured = fingerprint
        lock.unlock()

        if let expected = expected, expected != fingerprint {
            validationCompletePromise.fail(HostKeyMismatchError(
                expected: expected, actual: fingerprint
            ))
            return
        }
        validationCompletePromise.succeed(())
    }
}

struct HostKeyMismatchError: LocalizedError {
    let expected: String
    let actual: String

    var errorDescription: String? {
        "SSH host key changed — possible MITM attack. Expected \(SSHKeyFingerprint.display(expected)), got \(SSHKeyFingerprint.display(actual))."
    }
}
