import Foundation
import CryptoKit
import NIOCore
import NIOSSH
import Citadel

/// Persistent record of trusted SSH host keys, keyed by `host:port`.
/// A `nil` `storeURL` means "in-memory only, never persisted" — useful for
/// tests and other short-lived, isolated trust decisions.
public actor SSHHostKeyStore {

    /// Recomputes `defaultAppSupportURL` fresh on every persist, not just at
    /// `.shared`'s first access — so a transient failure to resolve/create the
    /// Application Support directory (disk full, container not yet mounted)
    /// self-heals on the next write instead of permanently disabling
    /// persistence for the rest of the process.
    public static let shared = SSHHostKeyStore(storeURLProvider: { defaultAppSupportURL })

    private struct Entry: Codable {
        var fingerprint: String   // "SHA256:<hex>"
        var firstSeen: Date
    }

    private struct File: Codable {
        var schemaVersion: Int = 1
        var entries: [String: Entry] = [:]
    }

    private let storeURLProvider: () -> URL?
    private var file: File?
    private var loaded = false

    public init(storeURL: URL?) {
        self.storeURLProvider = { storeURL }
    }

    private init(storeURLProvider: @escaping () -> URL?) {
        self.storeURLProvider = storeURLProvider
    }

    /// Returns the stored fingerprint for `host:port`, or `nil` if none.
    public func fingerprint(for host: String, port: Int) -> String? {
        ensureLoaded()
        return file?.entries[Self.key(host: host, port: port)]?.fingerprint
    }

    /// Records `fingerprint` as trusted for `host:port`. Overwrites any prior entry.
    public func record(host: String, port: Int, fingerprint: String) throws {
        try mutate { file in
            file.entries[Self.key(host: host, port: port)] = Entry(
                fingerprint: fingerprint, firstSeen: Date()
            )
        }
    }

    /// Forgets the stored entry for `host:port`, if any.
    public func forget(host: String, port: Int) throws {
        try mutate { file in
            file.entries.removeValue(forKey: Self.key(host: host, port: port))
        }
    }

    /// Forgets the entry identified by its `"host:port"` key.
    public func forget(id: String) throws {
        try mutate { file in
            file.entries.removeValue(forKey: id)
        }
    }

    /// Forgets every trusted host key.
    public func forgetAll() throws {
        try mutate { file in
            file.entries.removeAll()
        }
    }

    /// A trusted host, for display/management in Settings.
    public struct TrustedHost: Identifiable, Sendable {
        public let id: String          // "host:port"
        public let host: String
        public let port: Int
        public let fingerprint: String
        public let firstSeen: Date
    }

    /// All trusted host keys, sorted by host.
    public func trustedHosts() -> [TrustedHost] {
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

    private static var defaultAppSupportURL: URL? {
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

    private func decodeFile(at url: URL) -> File? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(File.self, from: data)
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = storeURLProvider() else { file = File(); return }
        file = decodeFile(at: url) ?? File()
    }

    /// Applies `change` to the freshest on-disk state (re-read right before
    /// writing, not the possibly-stale in-memory snapshot from an earlier
    /// `ensureLoaded()`) and persists the result. This narrows — though,
    /// without an OS-level file lock, doesn't fully eliminate — the
    /// lost-update window when multiple `tport` processes trust different
    /// new hosts concurrently against the same `known_hosts.json`.
    private func mutate(_ change: (inout File) -> Void) throws {
        var current: File
        if let url = storeURLProvider() {
            current = decodeFile(at: url) ?? file ?? File()
        } else {
            current = file ?? File()
        }
        change(&current)
        file = current
        loaded = true
        try persist()
    }

    private func persist() throws {
        guard let file = file, let url = storeURLProvider() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: url, options: [.atomic])
    }
}

// MARK: - Fingerprint helpers

public enum SSHKeyFingerprint {
    /// Compute the OpenSSH-style SHA256 fingerprint for a public key.
    public static func sha256(of key: NIOSSHPublicKey) -> String {
        var buf = ByteBufferAllocator().buffer(capacity: 256)
        _ = key.write(to: &buf)
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        let digest = SHA256.hash(data: Data(bytes))
        return "SHA256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Friendlier display: groups of two hex digits separated by colons.
    public static func display(_ fingerprint: String) -> String {
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
/// First-use confirmation is *not* done here — that requires a trust decision
/// (a UI dialog for the GUI, a flag check for the CLI) and is handled by the
/// `onUnknownHostKey` closure injected into `SFTPClient.connect`, which runs a
/// one-shot connection with `expected = nil` to capture the fingerprint, then
/// asks the closure before recording it.
public final class CapturingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {

    /// Set when constructed for a known-host connection. Mismatch → handshake fails.
    public let expected: String?

    private let lock = NSLock()
    private var _captured: String?

    public init(expected: String? = nil) {
        self.expected = expected
    }

    /// Fingerprint captured during the handshake (if any).
    public var captured: String? {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
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

public struct HostKeyMismatchError: LocalizedError {
    public let expected: String
    public let actual: String

    public var errorDescription: String? {
        "SSH host key changed — possible MITM attack. Expected \(SSHKeyFingerprint.display(expected)), got \(SSHKeyFingerprint.display(actual))."
    }
}
