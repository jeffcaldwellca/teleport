// SFTPClient.swift
// SFTP implementation using Citadel (orlandos-nl/Citadel) which wraps SwiftNIO + SwiftNIOSSH.
// Passwords and ed25519 key auth are supported.

import Foundation
import CryptoKit
import Citadel
import NIOCore
import NIOPosix
import NIOSSH
import Logging
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
    ///     (host, port, fingerprint) → trust? Called before any credentials are
    ///     sent to the host. Defaults to `false` (fail closed).
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

    /// Citadel logs every request at `info`; with swift-log's default handler
    /// that lands on stderr, burying tport's own output.
    private static let logger: Logger = {
        var logger = Logger(label: "teleport.sftp")
        logger.logLevel = .warning
        return logger
    }()

    // MARK: - Connect

    public func connect() async throws {
        // Reconnect-safe: tear down any previous session first so a reconnect
        // (e.g. the browser's self-heal path) doesn't leak the old SSH channel
        // and its NIO resources.
        if ssh != nil || sftp != nil { await disconnect() }

        let authMethod: SSHAuthenticationMethod = try await buildAuthMethod()

        // Host-key validation:
        //   1. Look up any previously-trusted fingerprint for this host:port.
        //   2. If there is none, learn the key and get it confirmed *before*
        //      authenticating (see `confirmUnknownHostKey`).
        //   3. Connect pinned to that fingerprint: a mismatch fails the
        //      handshake (MITM defence) before any credentials are sent.
        var expected = await hostKeyStore.fingerprint(for: connection.host, port: connection.port)
        if expected == nil {
            expected = try await confirmUnknownHostKey()
        }
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
        } catch {
            throw translateConnectFailure(error)
        }
        ssh = client

        do {
            sftp = try await client.openSFTP(logger: Self.logger)
        } catch {
            throw translateConnectFailure(error)
        }
    }

    /// First contact with a host: learn its key and ask `onUnknownHostKey`
    /// whether to trust it, returning the fingerprint to pin.
    ///
    /// Asking only after a full connect would hand the password to a server
    /// nobody has vouched for, so the key is fetched by `HostKeyProbe` — a
    /// bare key exchange that carries no credentials and never authenticates.
    private func confirmUnknownHostKey() async throws -> String {
        let fingerprint: String
        do {
            fingerprint = try await HostKeyProbe.fingerprint(host: connection.host, port: connection.port)
        } catch {
            throw translateConnectFailure(error)
        }

        guard await onUnknownHostKey(connection.host, connection.port, fingerprint) else {
            throw RemoteClientError.hostKeyUntrusted(
                host: connection.host, port: connection.port, fingerprint: fingerprint
            )
        }
        // A failed disk write only costs a repeat prompt next time; this
        // connection still pins the fingerprint the user just approved.
        try? await hostKeyStore.record(
            host: connection.host, port: connection.port, fingerprint: fingerprint
        )
        return fingerprint
    }

    /// Neither SwiftNIO's `NIOConnectionError` nor Citadel's error types
    /// (`AuthenticationFailed`, `SSHClientError`, `CitadelError`, …) conform to
    /// `LocalizedError`. Foundation therefore bridges them to a bare NSError,
    /// and every caller that reports `error.localizedDescription` — which is
    /// what the GUI's alerts and the connection editor's test button do —
    /// renders them as "The operation couldn't be completed.
    /// (NIOPosix.NIOConnectionError error 1.)": no host, no port, no reason.
    ///
    /// Translate them at this boundary so a failed connect always says what
    /// actually went wrong. `FTPClient` already reports at this level of
    /// detail; this brings SFTP in line.
    private func translateConnectFailure(_ error: Error) -> Error {
        let target = "\(connection.host):\(connection.port)"

        if error is AuthenticationFailed { return RemoteClientError.authenticationFailed }
        if let ssh = error as? SSHClientError, case .allAuthenticationOptionsFailed = ssh {
            return RemoteClientError.authenticationFailed
        }

        switch error {
        case let nio as NIOConnectionError:
            // DNS failures carry no `connectionErrors` — report the lookup instead.
            if let dns = nio.dnsAError ?? nio.dnsAAAAError {
                return RemoteClientError.connectionFailed(
                    "Could not resolve \(connection.host) — \(dns)"
                )
            }
            let reasons = nio.connectionErrors
                .map { String(describing: $0.error) }
                .joined(separator: "; ")
            return RemoteClientError.connectionFailed(
                "Could not reach \(target)\(reasons.isEmpty ? "" : " — \(reasons)"). " +
                "Check that the host, port, and protocol are correct."
            )

        // Anything already carrying its own message (including RemoteClientError)
        // is left alone — it already survives `localizedDescription`.
        case let localized as LocalizedError where localized.errorDescription != nil:
            return error

        default:
            return RemoteClientError.connectionFailed("Could not connect to \(target) — \(error)")
        }
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

        // Resume from staged bytes when asked and they're fewer than the
        // source; otherwise start clean.
        let startOffset = UInt64(DownloadStaging.resumeOffset(for: localURL, resume: resume, total: total))

        let file = try await sftp.openFile(filePath: remotePath, flags: .read)
        // Large files are read over several SFTP channels at once (see
        // `downloadChannels`); `files[0]` is the primary handle.
        let extras = total - Int64(startOffset) >= Self.multiChannelThreshold
            ? await openExtraReadChannels(for: remotePath) : []
        let files = [file] + extras.map(\.file)
        do {
            // Written to a staging file (see DownloadStaging); not truncated
            // when resuming so prior bytes survive.
            let fh = try DownloadStaging.openPartial(for: localURL, truncate: startOffset == 0)
            defer { try? fh.close() }
            if startOffset > 0 { try fh.seek(toOffset: startOffset) }

            var offset = startOffset          // next byte to write locally
            var nextRequest = startOffset     // next offset to ask the server for
            let chunkSize = Self.transferChunkSize
            progress(Int64(offset), total)

            // Keep several read requests in flight (see `pipelineDepth`) and
            // write their replies in order. Without a known size there's no
            // telling where to stop asking, so that case stays one at a time.
            let depth = total > 0 ? Self.pipelineDepth : 1
            var inFlight: [Task<ByteBuffer, Error>] = []
            var requestCount = 0
            defer { inFlight.forEach { $0.cancel() } }

            while true {
                try Task.checkCancellation()
                while inFlight.count < depth,
                      total > 0 ? nextRequest < UInt64(total) : inFlight.isEmpty {
                    let at = nextRequest
                    let source = files[requestCount % files.count]
                    requestCount += 1
                    inFlight.append(Task { try await source.read(from: at, length: UInt32(chunkSize)) })
                    nextRequest += UInt64(chunkSize)
                }
                guard !inFlight.isEmpty else { break }       // everything requested and written
                var buf = try await inFlight.removeFirst().value
                guard buf.readableBytes > 0 else { break }   // EOF
                let chunk = buf.readData(length: buf.readableBytes) ?? Data()
                try fh.write(contentsOf: chunk)   // throwing write: disk-full must fail the transfer
                offset += UInt64(chunk.count)
                progress(Int64(offset), total)

                // A short read mid-file: the requests already in flight assumed
                // a full chunk here, so drop them and ask again from where the
                // data really ends.
                if chunk.count < chunkSize, !inFlight.isEmpty {
                    inFlight.forEach { $0.cancel() }
                    inFlight.removeAll()
                    nextRequest = offset
                }
            }
            try await file.close()
            await closeExtraReadChannels(extras)

            // Integrity check: EOF alone isn't proof we got the whole file if
            // the server reported a size up front.
            if total > 0 && Int64(offset) != total {
                throw RemoteClientError.transferFailed(
                    "Incomplete download: received \(offset) of \(total) bytes"
                )
            }
            try fh.close()
            try DownloadStaging.commit(to: localURL)
        } catch {
            try? await file.close()
            await closeExtraReadChannels(extras)
            DownloadStaging.discardEmptyPartial(for: localURL)
            throw error
        }
    }

    private typealias ReadChannel = (client: Citadel.SFTPClient, file: SFTPFile)

    /// Open additional SFTP channels on this SSH connection, each with its own
    /// handle on `remotePath`. Best effort: a server that refuses more
    /// channels (e.g. a low `MaxSessions`) just leaves the download on fewer.
    private func openExtraReadChannels(for remotePath: String) async -> [ReadChannel] {
        guard let ssh else { return [] }
        var channels: [ReadChannel] = []
        for _ in 1..<Self.downloadChannels {
            guard let client = try? await ssh.openSFTP(logger: Self.logger) else { break }
            guard let file = try? await client.openFile(filePath: remotePath, flags: .read) else {
                try? await client.close()
                break
            }
            channels.append((client, file))
        }
        return channels
    }

    private func closeExtraReadChannels(_ channels: [ReadChannel]) async {
        for channel in channels {
            try? await channel.file.close()
            try? await channel.client.close()
        }
    }

    /// Bytes per SFTP read/write request. Citadel splits writes at 32,000
    /// bytes, so anything larger would cost an extra round trip per chunk.
    private static let transferChunkSize: Int = 32_000

    /// Read/write requests kept in flight at once (~1 MB). SFTP answers each
    /// request individually; waiting for every reply before sending the next
    /// caps throughput at one chunk per network round trip.
    private static let pipelineDepth = 32

    /// SFTP channels a large download is spread across. SwiftNIO SSH fixes
    /// each channel's receive window at 128 KB, so a single channel can take
    /// in at most that much per network round trip no matter how many reads
    /// are pipelined; every extra channel adds another window. Kept well
    /// under OpenSSH's default `MaxSessions` of 10.
    private static let downloadChannels = 6

    /// Downloads smaller than this aren't worth the extra channel setup.
    private static let multiChannelThreshold: Int64 = 4 * 1024 * 1024

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

            // Keep several write requests in flight (see `pipelineDepth`);
            // progress advances as the oldest one is acknowledged.
            var inFlight: [(end: UInt64, write: Task<Void, Error>)] = []
            defer { inFlight.forEach { $0.write.cancel() } }

            while true {
                try Task.checkCancellation()
                let chunk = fh.readData(ofLength: chunkSize)
                if chunk.isEmpty { break }
                let buf = allocator.buffer(bytes: chunk)
                let at = offset
                offset += UInt64(chunk.count)
                inFlight.append((offset, Task { try await file.write(buf, at: at) }))
                if inFlight.count >= Self.pipelineDepth {
                    let oldest = inFlight.removeFirst()
                    try await oldest.write.value
                    progress(Int64(oldest.end), total)
                }
            }
            while !inFlight.isEmpty {
                try Task.checkCancellation()
                let oldest = inFlight.removeFirst()
                try await oldest.write.value
                progress(Int64(oldest.end), total)
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
        try? await ping()
    }

    public func ping() async throws {
        guard let sftp else { throw RemoteClientError.notConnected }
        _ = try await sftp.getRealPath(atPath: ".")
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

// MARK: - Host key probe

/// Fetches a server's host-key fingerprint without logging in: runs the SSH
/// key exchange on a connection of its own, records the key the server
/// presents, refuses it, and closes the connection.
///
/// Done with SwiftNIO SSH directly rather than through Citadel because
/// Citadel leaves the TCP connection open when a handshake is refused — each
/// probe would hold a half-open session until the server's login timeout.
/// Citadel's default configuration adds no algorithms of its own, so the
/// probe negotiates the same host key the real connection will see.
///
/// All state is confined to the channel's event loop.
private final class HostKeyProbe: ChannelInboundHandler,
                                  NIOSSHClientServerAuthenticationDelegate,
                                  NIOSSHClientUserAuthenticationDelegate,
                                  @unchecked Sendable {
    typealias InboundIn = Any

    private static let timeout: TimeAmount = .seconds(30)

    private let result: EventLoopPromise<String>
    private var finished = false

    private init(result: EventLoopPromise<String>) {
        self.result = result
    }

    static func fingerprint(host: String, port: Int) async throws -> String {
        let loop = MultiThreadedEventLoopGroup.singleton.any()
        let probe = HostKeyProbe(result: loop.makePromise(of: String.self))

        let channel: Channel
        do {
            channel = try await connect(probe, host: host, port: port, on: loop)
        } catch {
            // Never reached a server: settle the promise so it isn't leaked.
            loop.execute { probe.finish(.failure(error)) }
            throw error
        }

        // A server that accepts the connection but never sends a key.
        let deadline = loop.scheduleTask(in: timeout) {
            probe.finish(.failure(RemoteClientError.connectionFailed(
                "\(host):\(port) did not present an SSH host key"
            )))
        }
        defer {
            deadline.cancel()
            channel.close(promise: nil)
        }
        return try await probe.result.futureResult.get()
    }

    private static func connect(
        _ probe: HostKeyProbe, host: String, port: Int, on loop: EventLoop
    ) async throws -> Channel {
        try await ClientBootstrap(group: loop)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHClientConfiguration(
                        userAuthDelegate: probe, serverAuthDelegate: probe
                    )
                    try channel.pipeline.syncOperations.addHandlers(
                        NIOSSHHandler(role: .client(configuration),
                                      allocator: channel.allocator,
                                      inboundChildChannelInitializer: nil),
                        probe
                    )
                }
            }
            .connect(host: host, port: port)
            .get()
    }

    private func finish(_ outcome: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        result.completeWith(outcome)
    }

    // Key exchange reached the host key: record it and go no further.
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = SSHKeyFingerprint.sha256(of: hostKey)
        finish(.success(fingerprint))
        validationCompletePromise.fail(UnknownHostKeyError(fingerprint: fingerprint))
    }

    // Never reached (the key is always refused); offer nothing regardless.
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextChallengePromise.succeed(nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failure(RemoteClientError.connectionFailed("the server closed the connection during the SSH handshake")))
        context.fireChannelInactive()
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
