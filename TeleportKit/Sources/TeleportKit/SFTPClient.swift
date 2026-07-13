// SFTPClient.swift
// SFTP implementation using Citadel (orlandos-nl/Citadel) which wraps SwiftNIO + SwiftNIOSSH.
// Passwords and ed25519 key auth are supported.

import Foundation
import CryptoKit
import Citadel
import NIOCore
import NIOPosix
import Darwin

public actor SFTPClient: RemoteClient {

    private let connection: Connection
    private let password: String
    private let hostKeyStore: SSHHostKeyStore
    private let keyReader: @Sendable (URL) async throws -> Data
    private let onUnknownHostKey: @Sendable (String, Int, String) async -> Bool

    private var ssh: SSHClient?
    private var sftp: Citadel.SFTPClient?

    /// - Parameters:
    ///   - hostKeyStore: where trusted host-key fingerprints are looked up and
    ///     recorded. Defaults to `.shared` (the app's Application Support
    ///     store) purely as a harmless default for ad hoc/test use — real
    ///     callers should pass one explicitly when the default's persistence
    ///     location matters.
    ///   - keyReader: reads the bytes of an SSH private key file. Defaults to
    ///     a plain `Data(contentsOf:)`. The GUI app supplies a closure that
    ///     tries a sandbox-scoped bookmark first, falling back to a direct read.
    ///   - onUnknownHostKey: asked to trust a host key seen for the first time
    ///     (host, port, fingerprint) → trust? Defaults to `false` (fail closed).
    ///     The GUI app supplies a closure that shows a confirmation dialog.
    public init(
        connection: Connection,
        password: String,
        hostKeyStore: SSHHostKeyStore = .shared,
        keyReader: @escaping @Sendable (URL) async throws -> Data = { url in try Data(contentsOf: url) },
        onUnknownHostKey: @escaping @Sendable (String, Int, String) async -> Bool = { _, _, _ in false }
    ) {
        self.connection = connection
        self.password   = password
        self.hostKeyStore = hostKeyStore
        self.keyReader = keyReader
        self.onUnknownHostKey = onUnknownHostKey
    }

    // MARK: - Connect

    public func connect() async throws {
        // Reconnect-safe: tear down any previous session first so a reconnect
        // (e.g. the browser's self-heal path) doesn't leak the old SSH channel
        // and its NIO resources.
        if ssh != nil || sftp != nil { await disconnect() }

        let authMethod: SSHAuthenticationMethod = try await buildAuthMethod()

        // Host-key validation:
        //   1. Look up any previously-trusted fingerprint for this host:port.
        //   2. Connect with a CapturingHostKeyValidator. If `expected` is set,
        //      mismatch fails the handshake (MITM defence).
        //   3. On a first-use connection, ask `onUnknownHostKey` before
        //      recording it. Declining leaves the connection closed.
        let expected = await hostKeyStore.fingerprint(for: connection.host, port: connection.port)
        let validator = CapturingHostKeyValidator(expected: expected)

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: connection.host,
                port: connection.port,
                authenticationMethod: authMethod,
                hostKeyValidator: .custom(validator),
                reconnect: .never
            )
        } catch let mismatch as HostKeyMismatchError {
            throw RemoteClientError.hostKeyMismatch(
                host: connection.host, port: connection.port,
                expected: mismatch.expected, actual: mismatch.actual
            )
        }
        ssh = client

        // First-use confirmation (no expected fingerprint in store).
        if expected == nil, let captured = validator.captured {
            let trusted = await onUnknownHostKey(connection.host, connection.port, captured)
            guard trusted else {
                try? await client.close()
                ssh = nil
                throw RemoteClientError.hostKeyUntrusted(
                    host: connection.host, port: connection.port, fingerprint: captured
                )
            }
            do {
                try await hostKeyStore.record(
                    host: connection.host, port: connection.port, fingerprint: captured
                )
            } catch {
                // Trust granted but disk-write failed — connection is already up,
                // continue but warn via the next connect attempt.
            }
        }

        sftp = try await client.openSFTP()
    }

    private func buildAuthMethod() async throws -> SSHAuthenticationMethod {
        let user = connection.username

        // If the user configured a key path, we *only* attempt key auth.
        // Silently falling back to password auth is dangerous — it leaks
        // whatever string is in the password field over the wire when the
        // user thought they were using a key.
        guard connection.sshKeyPath.isEmpty else {
            return try await buildKeyAuth(user: user)
        }

        return .passwordBased(username: user, password: password)
    }

    private func buildKeyAuth(user: String) async throws -> SSHAuthenticationMethod {
        let keyURL = URL(fileURLWithPath: (connection.sshKeyPath as NSString).expandingTildeInPath)
        let keyData = try await keyReader(keyURL)

        guard let keyString = String(data: keyData, encoding: .utf8) else {
            throw RemoteClientError.unsupported(
                "SSH key at \(keyURL.path) isn't a readable text key file (OpenSSH/PEM)."
            )
        }

        // Citadel parses the standard OpenSSH private-key container. Try ed25519
        // first, then RSA — the on-disk format is the same `-----BEGIN OPENSSH
        // PRIVATE KEY-----` wrapper for both, so we detect by attempting each.
        if let key = try? Curve25519.Signing.PrivateKey(sshEd25519: keyString) {
            return .ed25519(username: user, privateKey: key)
        }
        if let key = try? Insecure.RSA.PrivateKey(sshRsa: keyString) {
            return .rsa(username: user, privateKey: key)
        }

        // Passphrase-protected keys parse only with a decryption key, which we
        // don't prompt for yet — surface a clear, actionable message.
        if keyString.contains("ENCRYPTED") || keyString.contains("aes256-ctr") {
            throw RemoteClientError.unsupported(
                "Passphrase-protected SSH keys aren't supported yet. Remove the passphrase " +
                "(`ssh-keygen -p -f \(keyURL.lastPathComponent)`) or use password authentication."
            )
        }
        throw RemoteClientError.unsupported(
            "Unsupported SSH key at \(keyURL.path). Supported formats: unencrypted OpenSSH " +
            "ed25519 or RSA private keys."
        )
    }

    // MARK: - Disconnect

    public func disconnect() async {
        try? await sftp?.close()
        try? await ssh?.close()
        sftp = nil
        ssh = nil
    }

    // MARK: - List Directory

    public func listDirectory(at absolutePath: String) async throws -> [FileItem] {
        guard let sftp else { throw RemoteClientError.notConnected }

        // listDirectory returns [SFTPMessage.Name]; each Name contains a batch of SFTPPathComponent entries
        let batches = try await sftp.listDirectory(atPath: absolutePath)
        let entries = batches.flatMap(\.components)

        return entries.compactMap { entry -> FileItem? in
            guard let name = RemotePath.sanitizedFilename(entry.filename) else { return nil }
            let path = absolutePath.hasSuffix("/")
                ? "\(absolutePath)\(name)"
                : "\(absolutePath)/\(name)"
            let attrs = entry.attributes

            return FileItem(
                name: name,
                path: path,
                isDirectory: attrs.isDirectory,
                isSymlink: attrs.isSymlink,
                size: attrs.size.map(Int64.init),
                modifiedDate: attrs.modifiedDate,
                permissions: attrs.permissions.map { String($0, radix: 8) },
                owner: attrs.uidgid.map { String($0.userId) },
                group: attrs.uidgid.map { String($0.groupId) }
            )
        }
    }

    // MARK: - Download

    public func download(
        remotePath: String,
        to localURL: URL,
        resume: Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard let sftp else { throw RemoteClientError.notConnected }

        let attrs = try await sftp.getAttributes(at: remotePath)
        let total = attrs.size.map(Int64.init) ?? 0

        // Resume from the partial local file when asked and it's smaller than
        // the source; otherwise start clean.
        var startOffset: UInt64 = 0
        if resume,
           let existing = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]) as? Int64,
           existing > 0, total > 0, existing < total {
            startOffset = UInt64(existing)
        }

        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        do {
            // O_NOFOLLOW; don't truncate when resuming so prior bytes survive.
            let fh = try Self.openForWriting(at: localURL, truncate: startOffset == 0)
            defer { try? fh.close() }
            if startOffset > 0 { try fh.seek(toOffset: startOffset) }

            var offset = startOffset
            let chunkSize = Self.transferChunkSize
            progress(Int64(offset), total)

            while true {
                try Task.checkCancellation()
                var buf = try await file.read(from: offset, length: UInt32(chunkSize))
                guard buf.readableBytes > 0 else { break }
                let chunk = buf.readData(length: buf.readableBytes) ?? Data()
                try fh.write(contentsOf: chunk)   // throwing write: disk-full must fail the transfer
                offset += UInt64(chunk.count)
                progress(Int64(offset), total)
            }
            try await file.close()

            // Integrity check: EOF alone isn't proof we got the whole file if
            // the server reported a size up front.
            if total > 0 && Int64(offset) != total {
                throw RemoteClientError.transferFailed(
                    "Incomplete download: received \(offset) of \(total) bytes"
                )
            }
        } catch {
            try? await file.close()
            throw error
        }
    }

    /// Open a destination file for writing, refusing to follow symlinks.
    /// Defends against an attacker pre-placing a symlink at a predicted path.
    private static func openForWriting(at url: URL, truncate: Bool = true) throws -> FileHandle {
        var flags: Int32 = O_WRONLY | O_CREAT | O_NOFOLLOW
        if truncate { flags |= O_TRUNC }
        let fd = url.path.withCString { path in
            Darwin.open(path, flags, 0o644)
        }
        guard fd >= 0 else {
            let err = errno
            throw RemoteClientError.transferFailed(
                "Could not open destination: \(String(cString: strerror(err)))"
            )
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static let transferChunkSize: Int = 32 * 1024

    // MARK: - File Existence Check

    public func fileExists(at remotePath: String) async -> Bool {
        guard let sftp else { return false }
        return (try? await sftp.getAttributes(at: remotePath)) != nil
    }

    public func remoteModifiedDate(at remotePath: String) async -> Date? {
        guard let sftp else { return nil }
        return try? await sftp.getAttributes(at: remotePath).modifiedDate
    }

    // MARK: - Upload

    public func upload(
        from localURL: URL,
        remotePath: String,
        resume: Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        guard let sftp else { throw RemoteClientError.notConnected }

        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attrs[.size] as? Int64) ?? 0
        let fh = try FileHandle(forReadingFrom: localURL)
        defer { try? fh.close() }

        // Resume from the partial remote file when asked and it's smaller than
        // the source; otherwise create/truncate.
        var startOffset: UInt64 = 0
        if resume,
           let remoteSize = try? await sftp.getAttributes(at: remotePath).size,
           remoteSize > 0, total > 0, Int64(remoteSize) < total {
            startOffset = UInt64(remoteSize)
            try fh.seek(toOffset: startOffset)
        }

        let openFlags: SFTPOpenFileFlags = startOffset > 0 ? [.write] : [.write, .create, .truncate]
        let file = try await sftp.openFile(filePath: remotePath, flags: openFlags)
        do {
            let chunkSize = Self.transferChunkSize
            var offset = startOffset
            let allocator = ByteBufferAllocator()
            progress(Int64(offset), total)
            while true {
                try Task.checkCancellation()
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                let buf = allocator.buffer(bytes: chunk)
                try await file.write(buf, at: offset)
                offset += UInt64(chunk.count)
                progress(Int64(offset), total)
            }
            try await file.close()

            // Verify the remote file actually holds every byte we sent —
            // catches server-side truncation (e.g. disk full) that write calls
            // didn't surface.
            if total > 0,
               let remoteSize = try? await sftp.getAttributes(at: remotePath).size,
               Int64(remoteSize) != total {
                throw RemoteClientError.transferFailed(
                    "Incomplete upload: server has \(remoteSize) of \(total) bytes"
                )
            }
        } catch {
            try? await file.close()
            throw error
        }
    }

    // MARK: - Keep-Alive

    public func keepAlive() async {
        _ = try? await sftp?.getAttributes(at: connection.initialPath)
    }

    public func setModifiedDate(_ date: Date, at remotePath: String) async {
        guard let sftp else { return }
        var attrs = SFTPFileAttributes()
        attrs.accessModificationTime = .init(accessTime: date, modificationTime: date)
        try? await sftp.setAttributes(at: remotePath, to: attrs)
    }

    // MARK: - File Operations

    public func createDirectory(at absolutePath: String) async throws {
        guard let sftp else { throw RemoteClientError.notConnected }
        try await sftp.createDirectory(atPath: absolutePath)
    }

    public func delete(at absolutePath: String, isDirectory: Bool) async throws {
        guard let sftp else { throw RemoteClientError.notConnected }
        if isDirectory {
            try await sftp.rmdir(at: absolutePath)
        } else {
            try await sftp.remove(at: absolutePath)
        }
    }

    public func rename(from: String, to: String) async throws {
        guard let sftp else { throw RemoteClientError.notConnected }
        try await sftp.rename(at: from, to: to)
    }

    public func setPermissions(_ octal: Int, at absolutePath: String) async throws {
        guard let sftp else { throw RemoteClientError.notConnected }
        // UInt32(Int) traps on a negative value — reject it instead of crashing.
        guard let unsigned = UInt32(exactly: octal) else {
            throw RemoteClientError.unsupported("'\(octal)' isn't a valid permission value")
        }
        var attrs = SFTPFileAttributes()
        // Mask off file-type bits — only mode bits are settable per POSIX.
        attrs.permissions = unsigned & 0o7777
        try await sftp.setAttributes(at: absolutePath, to: attrs)
    }

    public func setOwnership(owner: String, group: String, at absolutePath: String) async throws {
        guard let sftp else { throw RemoteClientError.notConnected }
        guard let uid = UInt32(owner.trimmingCharacters(in: .whitespaces)),
              let gid = UInt32(group.trimmingCharacters(in: .whitespaces)) else {
            throw RemoteClientError.unsupported("SFTP ownership requires numeric User ID and Group ID (e.g. 1000)")
        }
        var attrs = SFTPFileAttributes()
        attrs.uidgid = .init(userId: uid, groupId: gid)
        try await sftp.setAttributes(at: absolutePath, to: attrs)
    }

}

// MARK: - SFTPFileAttributes helpers

private extension SFTPFileAttributes {
    var isDirectory: Bool {
        guard let perms = permissions else { return false }
        return (perms & 0o170000) == 0o040000
    }

    var isSymlink: Bool {
        guard let perms = permissions else { return false }
        return (perms & 0o170000) == 0o120000
    }

    var modifiedDate: Date? {
        accessModificationTime?.modificationTime
    }
}
