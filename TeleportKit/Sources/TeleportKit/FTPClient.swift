// FTPClient.swift
// Full FTP / FTPS implementation using POSIX sockets + SecureTransport.
// Control channel: one persistent connection per session.
// Data transfers: each spawns a separate FTP session to allow independent cancellation
// and avoid blocking the main control channel.

import Foundation
import Darwin
import Security
import CryptoKit

// MARK: - Errors

public enum FTPError: LocalizedError {
    case connectionFailed(String)
    case unexpectedResponse(Int, String)
    case authFailed
    case permissionDenied(String)
    case tlsSetupFailed(String)
    case noPassiveAddress
    case transferInterrupted(String)
    case listingFailed(String)
    case serverError(Int, String)
    /// The FTPS certificate isn't trusted by the system and hasn't been
    /// accepted by the user for this host.
    case untrustedCertificate(host: String, port: Int, fingerprint: String, reason: String)
    /// The FTPS certificate isn't trusted by the system and differs from the
    /// one the user previously accepted for this host.
    case certificateChanged(host: String, port: Int, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let m):          return "Connection failed: \(m)"
        case .unexpectedResponse(let c, let m): return "FTP \(c): \(m)"
        case .authFailed:                       return "Authentication failed"
        case .permissionDenied(let m):          return "Permission denied: \(m)"
        case .tlsSetupFailed(let m):            return "TLS setup failed: \(m)"
        case .noPassiveAddress:                 return "Server did not provide a passive address"
        case .transferInterrupted(let m):       return "Transfer interrupted: \(m)"
        case .listingFailed(let m):             return "Directory listing failed: \(m)"
        case .serverError(let c, let m):        return "Server error \(c): \(m)"
        case .untrustedCertificate(let host, let port, let fp, let reason):
            return "The certificate for \(host):\(port) is not trusted (\(reason)). " +
                   "Fingerprint \(SSHKeyFingerprint.display(fp)). " +
                   "Reconnect and choose to trust it if this is expected."
        case .certificateChanged(let host, let port, let expected, let actual):
            return "The certificate for \(host):\(port) has changed — possible MITM attack. " +
                   "Expected \(SSHKeyFingerprint.display(expected)), saw \(SSHKeyFingerprint.display(actual)). " +
                   "If this change is legitimate (e.g. the certificate was renewed), remove the trusted certificate and reconnect."
        }
    }
}

/// An FTPS certificate the system doesn't trust, put to the user for a
/// trust-on-first-use decision.
public struct UntrustedCertificate: Sendable {
    public let host: String
    public let port: Int
    /// "SHA256:<hex>" of the server's leaf certificate.
    public let fingerprint: String
    /// Why the system rejected it (self-signed, hostname mismatch, expired, …).
    public let reason: String
}

// MARK: - FTP Response

private struct FTPResponse {
    let code: Int
    let message: String
}

// MARK: - Low-Level Socket
// All I/O is blocking and must be called from a background DispatchQueue.

private final class FTPSocket {

    fileprivate(set) var fd: Int32 = -1
    // `fileprivate` so FTPClient (same file) can access for data-channel reads
    fileprivate var ssl: SSLContext?
    private var readBuf = Data()
    private var isClosed = false

    /// How long to wait for a TCP connect before giving up.
    static let connectTimeout: TimeInterval = 15
    /// `SO_RCVTIMEO` interval — a blocked recv returns this often so the read
    /// loop can poll for cancellation instead of hanging forever.
    static let recvTick: TimeInterval = 2
    /// Overall "no data at all" deadline before a read is declared stalled.
    static let idleTimeout: TimeInterval = 60
    /// Wall-clock cap on the TLS handshake.
    static let handshakeTimeout: TimeInterval = 30

    // MARK: Connect

    func connect(host: String, port: Int) throws {
        var hints = addrinfo()
        hints.ai_family   = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var res: UnsafeMutablePointer<addrinfo>?
        defer { if let r = res { freeaddrinfo(r) } }

        let rc = getaddrinfo(host, String(port), &hints, &res)
        if rc != 0 {
            throw FTPError.connectionFailed(String(cString: gai_strerror(rc)))
        }

        var connfd: Int32 = -1
        var ptr = res
        while let info = ptr {
            let s = socket(info.pointee.ai_family,
                           info.pointee.ai_socktype,
                           info.pointee.ai_protocol)
            if s >= 0 {
                if Self.connectWithTimeout(s, info.pointee.ai_addr, info.pointee.ai_addrlen,
                                           timeout: Self.connectTimeout) {
                    connfd = s
                    break
                }
                Darwin.close(s)
            }
            ptr = info.pointee.ai_next
        }

        guard connfd >= 0 else {
            throw FTPError.connectionFailed("Could not reach \(host):\(port) (connection timed out or refused)")
        }
        fd = connfd

        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &enable, socklen_t(MemoryLayout.size(ofValue: enable)))
        // A write to a connection the server already closed must fail with
        // EPIPE, not raise SIGPIPE — whose default action kills the process.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enable, socklen_t(MemoryLayout.size(ofValue: enable)))

        // Bound blocking reads and writes so the transfer loops can check
        // cancellation and enforce an idle deadline. Without the write bound,
        // a server that stops reading (or a path that silently drops) blocks
        // send() forever, and neither Cancel nor the stall watchdog can stop it.
        var tv = timeval(tv_sec: Int(Self.recvTick), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Non-blocking connect with a wall-clock timeout, then restores blocking mode.
    private static func connectWithTimeout(_ fd: Int32,
                                           _ addr: UnsafePointer<sockaddr>,
                                           _ len: socklen_t,
                                           timeout: TimeInterval) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, flags) }   // restore blocking

        if Darwin.connect(fd, addr, len) == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }  // timed out / error

        var soErr: Int32 = 0
        var soLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen) == 0 else { return false }
        return soErr == 0
    }

    // MARK: TLS Upgrade (SecureTransport)
    //
    // SecureTransport (`SSLContext`) is deprecated in macOS 10.15. It's still
    // in use here because Network.framework cannot perform a TLS upgrade on an
    // existing plaintext TCP connection (required for explicit FTPS / AUTH
    // TLS). Migration would require NIOSSL or an `NWFramer`-based mid-stream
    // TLS implementation. For now we ensure proper certificate validation
    // and a modern minimum TLS version, which closes the actual security gap.

    /// - Parameters:
    ///   - port: the control port, to name the server in trust errors.
    ///   - sessionID: shared by a session's control and data connections so
    ///     the data channel resumes the control channel's TLS session, which
    ///     many servers require (vsftpd `require_ssl_reuse`, ProFTPD, …).
    ///   - pinnedFingerprint: a certificate the user already accepted for
    ///     this server, honoured when system trust evaluation fails.
    func startTLS(serverName: String, port: Int, sessionID: String, pinnedFingerprint: String?) throws {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw FTPError.tlsSetupFailed("SSLCreateContext failed")
        }

        // C-function-pointer callbacks: non-capturing; fd is passed via the `connection` pointer.
        // SecureTransport asks for an exact byte count. Anything short of it
        // must be reported as "would block" (with the partial count), never as
        // success — a short read passed off as complete makes it parse a
        // truncated TLS record and fail the stream at random.
        let readFn: SSLReadFunc = { connection, data, dataLength -> OSStatus in
            let fd = Int32(Int(bitPattern: connection))
            let wanted = dataLength.pointee
            var got = 0
            while got < wanted {
                let n = Darwin.recv(fd, data.advanced(by: got), wanted - got, 0)
                if n > 0 { got += n; continue }
                if n < 0 && errno == EINTR { continue }
                dataLength.pointee = got
                if n == 0 { return OSStatus(errSSLClosedGraceful) }
                return (errno == EAGAIN || errno == EWOULDBLOCK)
                    ? OSStatus(errSSLWouldBlock) : OSStatus(errSecIO)
            }
            dataLength.pointee = got
            return noErr
        }

        let writeFn: SSLWriteFunc = { connection, data, dataLength -> OSStatus in
            let fd   = Int32(Int(bitPattern: connection))
            var sent = 0
            while sent < dataLength.pointee {
                let n = Darwin.send(fd, data.advanced(by: sent), dataLength.pointee - sent, 0)
                if n <= 0 {
                    dataLength.pointee = sent
                    return (errno == EAGAIN || errno == EWOULDBLOCK)
                        ? OSStatus(errSSLWouldBlock) : OSStatus(errSecIO)
                }
                sent += n
            }
            dataLength.pointee = sent
            return noErr
        }

        SSLSetIOFuncs(ctx, readFn, writeFn)
        SSLSetConnection(ctx, UnsafeRawPointer(bitPattern: Int(fd)))
        SSLSetPeerDomainName(ctx, serverName, serverName.utf8.count)
        SSLSetPeerID(ctx, sessionID, sessionID.utf8.count)

        // Refuse anything older than TLS 1.2.
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)

        // Take over certificate validation so we can enforce it.
        // Without this, validation behaviour depends on platform defaults and
        // historically has been opaque/permissive.
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)

        // Handshake loop. `errSSLPeerAuthCompleted` is the cue to evaluate
        // the server certificate ourselves — `noErr` only comes after we
        // re-call `SSLHandshake` post-evaluation.
        let deadline = Date().addingTimeInterval(Self.handshakeTimeout)
        while true {
            let status = SSLHandshake(ctx)
            switch status {
            case noErr:
                ssl = ctx
                return
            case OSStatus(errSSLPeerAuthCompleted):
                try Self.evaluateServerTrust(ctx, serverName: serverName, port: port,
                                             pinnedFingerprint: pinnedFingerprint)
                // Continue the handshake after successful trust evaluation.
            case OSStatus(errSSLWouldBlock):
                // A recv timed out (SO_RCVTIMEO) — keep waiting until the deadline.
                break
            default:
                throw FTPError.tlsSetupFailed("TLS handshake error \(status)")
            }
            if Date() > deadline {
                throw FTPError.tlsSetupFailed("TLS handshake timed out")
            }
        }
    }

    private static func evaluateServerTrust(
        _ ctx: SSLContext, serverName: String, port: Int, pinnedFingerprint: String?
    ) throws {
        var trust: SecTrust?
        let copyStatus = SSLCopyPeerTrust(ctx, &trust)
        guard copyStatus == errSecSuccess, let serverTrust = trust else {
            throw FTPError.tlsSetupFailed("Could not retrieve server certificate (status \(copyStatus))")
        }

        // Bind hostname into the trust evaluation policy so CN/SAN match.
        let policy = SecPolicyCreateSSL(true, serverName as CFString)
        SecTrustSetPolicies(serverTrust, policy)

        var cfError: CFError?
        if SecTrustEvaluateWithError(serverTrust, &cfError) { return }
        let reason = cfError.map { CFErrorCopyDescription($0) as String } ?? "untrusted"

        // Not trusted by the system (self-signed, private CA, name mismatch,
        // …): fall back to the exact certificate the user accepted, if any.
        guard let leaf = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate])?.first else {
            throw FTPError.tlsSetupFailed("Server certificate rejected: \(reason)")
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
        let fingerprint = "SHA256:" + digest.map { String(format: "%02x", $0) }.joined()

        guard let pinned = pinnedFingerprint else {
            throw FTPError.untrustedCertificate(
                host: serverName, port: port, fingerprint: fingerprint, reason: reason
            )
        }
        guard pinned == fingerprint else {
            throw FTPError.certificateChanged(
                host: serverName, port: port, expected: pinned, actual: fingerprint
            )
        }
    }

    // MARK: Write

    func writeLine(_ s: String) throws {
        try writeRaw(FTPNameEncoding.encode(s + "\r\n"))
    }

    /// Sends all of `data`. A send that times out (`SO_SNDTIMEO`) is retried
    /// after checking for cancellation, until nothing has gone out for the
    /// idle deadline.
    func writeRaw(_ data: Data) throws {
        var offset = 0
        var lastProgress = Date()
        while true {
            if Task.isCancelled { throw CancellationError() }
            let count = data.count - offset
            var written = 0
            var pending = false
            if let ctx = ssl {
                var processed = 0
                let status = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
                    // Called with nothing left to hand over, SSLWrite only
                    // flushes what it already encrypted.
                    SSLWrite(ctx, count > 0 ? ptr.baseAddress!.advanced(by: offset) : nil, count, &processed)
                }
                switch status {
                case noErr:                       written = processed
                case OSStatus(errSSLWouldBlock):  written = processed; pending = true
                default: throw FTPError.transferInterrupted("SSL write \(status)")
                }
            } else if count > 0 {
                let n = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                    Darwin.send(fd, ptr.baseAddress!.advanced(by: offset), count, 0)
                }
                if n > 0 {
                    written = n
                } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    pending = true
                } else {
                    throw FTPError.transferInterrupted("Socket write error")
                }
            }
            offset += written
            // Done once everything is handed over and, under TLS, flushed:
            // SecureTransport may still hold encrypted bytes after taking all
            // of ours, and they must go out before the connection is closed.
            if offset == data.count && !pending { return }
            if written > 0 {
                lastProgress = Date()
            } else if Date().timeIntervalSince(lastProgress) > Self.idleTimeout {
                throw FTPError.transferInterrupted("Timed out sending data to server")
            }
        }
    }

    // MARK: Read

    /// Read whatever is available into `tmp`, returning the byte count.
    /// Returns 0 only on a genuine peer close (EOF). Handles `SO_RCVTIMEO`
    /// ticks by polling cancellation and an idle deadline, so a stalled server
    /// can't hang the transfer and the user's Cancel takes effect promptly.
    private func readAvailable(into tmp: inout [UInt8], max: Int) throws -> Int {
        let deadline = Date().addingTimeInterval(Self.idleTimeout)
        while true {
            if Task.isCancelled { throw CancellationError() }
            var count = 0
            if let ctx = ssl {
                let status = SSLRead(ctx, &tmp, max, &count)
                switch status {
                case noErr where count > 0:                       return count
                case OSStatus(errSSLWouldBlock) where count > 0:  return count
                case noErr, OSStatus(errSSLWouldBlock):           break        // tick, keep waiting
                case OSStatus(errSSLClosedGraceful):              return 0      // EOF
                default: throw FTPError.transferInterrupted("SSL read \(status)")
                }
            } else {
                count = Darwin.recv(fd, &tmp, max, 0)
                if count > 0 { return count }
                if count == 0 { return 0 }                                     // EOF
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    throw FTPError.transferInterrupted("Socket read error (errno \(errno))")
                }
                // else: recv timeout tick, keep waiting
            }
            if Date() > deadline {
                throw FTPError.transferInterrupted("Timed out waiting for data from server")
            }
        }
    }

    private func fillBuffer() throws {
        var tmp = [UInt8](repeating: 0, count: 4096)
        let n = try readAvailable(into: &tmp, max: 4096)
        if n == 0 { throw FTPError.transferInterrupted("Connection closed") }
        readBuf.append(contentsOf: tmp[0 ..< n])
    }

    func readByte() throws -> UInt8 {
        if readBuf.isEmpty { try fillBuffer() }
        return readBuf.removeFirst()
    }

    func readLine() throws -> String {
        var line = Data()
        while true {
            let b = try readByte()
            if b == UInt8(ascii: "\n") { break }
            if b != UInt8(ascii: "\r") { line.append(b) }
        }
        // Not necessarily UTF-8: a Latin-1 banner, or a 257 reply naming a
        // folder in the server's own encoding (see FTPNameEncoding).
        return FTPNameEncoding.decode(line)
    }

    /// Read a chunk of data. Returns nil when the remote side closes the connection.
    func readChunk(maxBytes: Int = 65536) throws -> Data? {
        var tmp = [UInt8](repeating: 0, count: maxBytes)
        let n = try readAvailable(into: &tmp, max: maxBytes)
        return n == 0 ? nil : Data(tmp[0 ..< n])
    }

    /// Received but not yet read.
    var hasBufferedInput: Bool { !readBuf.isEmpty }

    /// The numeric address this socket is connected to.
    var peerAddress: String? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let gotPeer = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) == 0 }
        }
        guard gotPeer else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return rc == 0 ? String(cString: host) : nil
    }

    // MARK: Close

    func close() {
        guard !isClosed else { return }
        isClosed = true
        if let ctx = ssl { SSLClose(ctx); ssl = nil }
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { close() }
}

// MARK: - FTPClient

public actor FTPClient: RemoteClient {

    private let connection: Connection
    private let password: String
    private let certificateStore: SSHHostKeyStore
    private let onUntrustedCertificate: @Sendable (UntrustedCertificate) async -> Bool
    private let dedicatedToTransfers: Bool
    private var socket: FTPSocket?
    private var tlsActive = false
    /// Certificate the user accepted for this server (FTPS only), if any.
    private var pinnedCertificate: String?
    /// Ties this session's data connections to its control connection's TLS
    /// session; renewed on every (re)connect.
    private var tlsSessionID = UUID().uuidString

    // What this server turned out not to support, learned once per session
    // instead of re-probed on every operation. nil = not tried yet.
    private var supportsMLSD: Bool?
    private var supportsListAll: Bool?
    private var supportsEPSV: Bool?

    // FTP I/O here is blocking. Run this actor on a dedicated serial queue (a
    // real thread) instead of the Swift concurrency cooperative pool, so a slow
    // or concurrent transfer can't tie up a shared pool thread and stall every
    // other async task in the app.
    private let ioQueue = DispatchSerialQueue(label: "com.teleport.ftp.io")
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioQueue.asUnownedSerialExecutor()
    }

    /// - Parameters:
    ///   - certificateStore: where FTPS certificates the user chose to trust
    ///     are looked up and recorded (keyed by `host:port`, like SSH host keys).
    ///   - onUntrustedCertificate: asked whether to trust an FTPS certificate
    ///     the system rejects. Called before any credentials are sent.
    ///     Defaults to `false` (fail closed).
    ///   - dedicatedToTransfers: run uploads and downloads on this session's
    ///     own control connection instead of logging in a separate session
    ///     for each one. For a client nothing else uses concurrently (a queue
    ///     worker), where the per-file login would be pure overhead; a
    ///     browsing session leaves it off so a long transfer can't block
    ///     listings.
    public init(
        connection: Connection,
        password: String,
        certificateStore: SSHHostKeyStore = .tlsCertificates,
        onUntrustedCertificate: @escaping @Sendable (UntrustedCertificate) async -> Bool = { _ in false },
        dedicatedToTransfers: Bool = false
    ) {
        self.dedicatedToTransfers = dedicatedToTransfers
        self.connection = connection
        self.password   = password
        self.certificateStore = certificateStore
        self.onUntrustedCertificate = onUntrustedCertificate
    }

    /// After a transfer fails partway on the control connection its state is
    /// unknowable (a reply may still be in flight), so the session is dropped
    /// rather than reused.
    private func abandonSession() {
        socket?.close()
        socket = nil
        tlsActive = false
    }

    /// A separate session for one transfer, sharing this client's trust policy.
    private func makeTransferClient() -> FTPClient {
        FTPClient(connection: connection, password: password,
                  certificateStore: certificateStore,
                  onUntrustedCertificate: onUntrustedCertificate)
    }

    // No `deinit { socket?.close() }` — actor-isolated state cannot be
    // touched from a non-isolated deinit. Callers must `await disconnect()`.

    // MARK: - Connect

    public func connect() async throws {
        if connection.connectionProtocol == .ftps {
            pinnedCertificate = await certificateStore.fingerprint(
                for: connection.host, port: connection.port
            )
        }
        do {
            try connectSync()
        } catch FTPError.untrustedCertificate(let host, let port, let fingerprint, let reason) {
            // The handshake was abandoned before login, so nothing has been
            // sent yet. Ask, remember the answer, and start over pinned to
            // the certificate that was just approved.
            let certificate = UntrustedCertificate(
                host: host, port: port, fingerprint: fingerprint, reason: reason
            )
            guard await onUntrustedCertificate(certificate) else {
                throw FTPError.untrustedCertificate(
                    host: host, port: port, fingerprint: fingerprint, reason: reason
                )
            }
            // A failed disk write only costs a repeat prompt next time.
            try? await certificateStore.record(host: host, port: port, fingerprint: fingerprint)
            pinnedCertificate = fingerprint
            try connectSync()
        }
    }

    private func connectSync() throws {
        do {
            try establishSession()
        } catch {
            // Never leave a half-set-up socket behind for later commands.
            socket?.close()
            socket = nil
            tlsActive = false
            throw error
        }
    }

    private func startTLS(on sock: FTPSocket) throws {
        try sock.startTLS(serverName: connection.host, port: connection.port,
                          sessionID: tlsSessionID, pinnedFingerprint: pinnedCertificate)
    }

    private func establishSession() throws {
        // Reconnect-safe: drop any previous socket and, critically, reset
        // `tlsActive`. If it stayed true from a dead FTPS session, the AUTH TLS
        // upgrade below would be skipped and credentials would go out in
        // plaintext on the new socket.
        socket?.close()
        socket = nil
        tlsActive = false
        tlsSessionID = UUID().uuidString
        supportsMLSD = nil
        supportsListAll = nil
        supportsEPSV = nil

        let sock = FTPSocket()

        if connection.connectionProtocol == .ftps && connection.implicitTLS {
            // Implicit FTPS: TLS from the start
            try sock.connect(host: connection.host, port: connection.port)
            try startTLS(on: sock)
            tlsActive = true
        } else {
            try sock.connect(host: connection.host, port: connection.port)
        }

        socket = sock

        // Read welcome banner
        let banner = try readResponse()
        guard banner.code == 220 else {
            throw FTPError.unexpectedResponse(banner.code, banner.message)
        }

        // Explicit FTPS (AUTH TLS on port 21).
        // We refuse to fall through to plaintext credentials when FTPS was requested:
        // AUTH TLS, PBSZ, and PROT P must all succeed.
        if connection.connectionProtocol == .ftps && !tlsActive {
            let auth = try sendCommand("AUTH TLS")
            guard auth.code == 234 else {
                throw FTPError.tlsSetupFailed(
                    "Server refused AUTH TLS (\(auth.code) \(auth.message)). Refusing to send credentials over plaintext."
                )
            }
            // Nothing may follow the 234 in plaintext. Bytes already buffered
            // would be read later as if they had arrived over TLS, letting
            // someone on the path inject replies to PBSZ, PROT or USER.
            guard !sock.hasBufferedInput else {
                throw FTPError.tlsSetupFailed(
                    "The server sent more data after agreeing to start TLS. Refusing to continue, as this can mean the connection is being tampered with."
                )
            }
            try startTLS(on: sock)
            tlsActive = true
        }

        // RFC 4217: PBSZ then PROT — without PROT P the data channel is
        // plaintext. Implicit FTPS needs this too: the control channel being
        // encrypted from the start says nothing about the data channel, and
        // we always wrap data connections in TLS once `tlsActive` is set.
        if tlsActive {
            let pbsz = try sendCommand("PBSZ 0")
            guard pbsz.code == 200 else {
                throw FTPError.tlsSetupFailed(
                    "PBSZ rejected (\(pbsz.code) \(pbsz.message))."
                )
            }
            let prot = try sendCommand("PROT P")
            guard prot.code == 200 else {
                throw FTPError.tlsSetupFailed(
                    "Server refused encrypted data channel via PROT P (\(prot.code) \(prot.message))."
                )
            }
        }

        // Login
        let user = try sendCommand("USER \(connection.username)")
        switch user.code {
        case 230: break                           // No password needed
        case 331:
            let pass = try sendCommand("PASS \(password)")
            guard pass.code == 230 else { throw FTPError.authFailed }
        default:
            throw FTPError.authFailed
        }

        // Binary mode + optional UTF-8
        _ = try sendCommand("TYPE I")
        _ = try? sendCommand("OPTS UTF8 ON")
    }

    // MARK: - Disconnect

    public func disconnect() async {
        // Send QUIT as a courtesy but don't wait for the reply: on a dead or
        // half-dead connection, reading the response blocks for the full idle
        // timeout (60s), which stalls retry loops and disconnect paths.
        if let s = socket {
            try? s.writeLine("QUIT")
            s.close()
        }
        socket = nil
        tlsActive = false
    }

    // MARK: - List Directory

    public func listDirectory(at absolutePath: String) async throws -> [FileItem] {
        try listSync(path: absolutePath)
    }

    private func listSync(path: String) throws -> [FileItem] {
        // Prefer MLSD (machine-readable); fall back to LIST. A server that
        // doesn't know the command is remembered, so it isn't asked again on
        // every listing.
        if supportsMLSD != false {
            do {
                let items = try mlsdSync(path: path)
                supportsMLSD = true
                return items
            } catch is CancellationError {
                throw CancellationError()
            } catch FTPError.serverError(let code, _) where Self.isUnknownCommand(code) {
                supportsMLSD = false
            } catch {
                // Anything else: let LIST report what's actually wrong.
            }
        }
        return try listRawSync(path: path)
    }

    /// Reply codes meaning "this server doesn't implement that command".
    private static func isUnknownCommand(_ code: Int) -> Bool {
        code == 500 || code == 502 || code == 504
    }

    private func mlsdSync(path: String) throws -> [FileItem] {
        let data = try openDataConnectionAndRun(command: "MLSD \(path)")
        return FTPListingParser.lines(of: data)
            .compactMap { FTPListingParser.mlsdLine($0, basePath: path) }
            .filter { $0.name != "." && $0.name != ".." }
    }

    private func listRawSync(path: String) throws -> [FileItem] {
        // Plain LIST leaves out dotfiles on most servers, so ask for them.
        // "-a" is a de-facto convention, not part of the protocol: a server
        // that rejects it, or answers with nothing at all (even an empty
        // directory lists "." and ".." under -a), gets the plain form.
        if supportsListAll != false {
            do {
                let lines = try listLines(command: "LIST -a \(path)")
                if !lines.isEmpty {
                    supportsListAll = true
                    return Self.parseListLines(lines, basePath: path)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch FTPError.serverError(let code, _) where Self.isUnknownCommand(code) || code == 501 {
                supportsListAll = false
            } catch {
                // e.g. 550: "-a" taken for a file name, or the directory
                // really is missing — the plain LIST below settles which.
            }
        }
        return Self.parseListLines(try listLines(command: "LIST \(path)"), basePath: path)
    }

    private func listLines(command: String) throws -> [String] {
        let data = try openDataConnectionAndRun(command: command)
        return FTPListingParser.lines(of: data)
    }

    private static func parseListLines(_ lines: [String], basePath: String) -> [FileItem] {
        lines
            .compactMap { FTPListingParser.listLine($0, basePath: basePath) }
            .filter { $0.name != "." && $0.name != ".." }
    }

    // MARK: - Download

    public func download(
        remotePath: String,
        to localURL: URL,
        resume: Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        if dedicatedToTransfers {
            do {
                try performDownload(remotePath: remotePath, to: localURL, resume: resume, progress: progress)
            } catch {
                abandonSession()
                DownloadStaging.discardEmptyPartial(for: localURL)
                throw error
            }
            return
        }
        let xfer = makeTransferClient()
        try await xfer.connect()
        do {
            try await xfer.performDownload(
                remotePath: remotePath, to: localURL, resume: resume, progress: progress
            )
            await xfer.disconnect()
        } catch {
            await xfer.disconnect()
            DownloadStaging.discardEmptyPartial(for: localURL)
            throw error
        }
    }

    private func performDownload(
        remotePath: String,
        to localURL: URL,
        resume: Bool,
        progress: @Sendable (Int64, Int64) -> Void
    ) throws {
        var totalBytes: Int64 = 0
        if let r = try? sendCommand("SIZE \(remotePath)"), r.code == 213,
           let n = Int64(r.message.trimmingCharacters(in: .whitespaces)) {
            totalBytes = n
        }

        let dataSock = try openDataConnection()
        defer { dataSock.close() }

        // Resume from staged bytes when asked and the server accepts REST.
        // REST is sent after PASV/EPSV, immediately before RETR — some servers
        // reset the restart marker on intervening commands.
        var startOffset = DownloadStaging.resumeOffset(for: localURL, resume: resume, total: totalBytes)
        if startOffset > 0 {
            let rest = try sendCommand("REST \(startOffset)")
            if rest.code != 350 { startOffset = 0 }   // fall back to full
        }

        // Written to a staging file (see DownloadStaging); only truncated on
        // a clean (non-resume) start.
        let fh = try DownloadStaging.openPartial(for: localURL, truncate: startOffset == 0)
        defer { try? fh.close() }
        if startOffset > 0 { try fh.seek(toOffset: UInt64(startOffset)) }

        let resp = try sendCommand("RETR \(remotePath)")
        if resp.code == 550 {
            throw FTPError.permissionDenied(resp.message)
        }
        guard resp.code == 125 || resp.code == 150 else {
            throw FTPError.unexpectedResponse(resp.code, resp.message)
        }
        try secureDataConnection(dataSock)

        var received = startOffset
        progress(received, totalBytes)
        while let chunk = try dataSock.readChunk() {
            try Task.checkCancellation()
            try fh.write(contentsOf: chunk)   // throwing write: disk-full must fail the transfer
            received += Int64(chunk.count)
            progress(received, totalBytes)
        }

        // The data channel hitting EOF is NOT proof of success — a dropped
        // connection looks identical. The server's final reply and the byte
        // count are the integrity check; without them a truncated file would
        // be reported as complete.
        let final = try readResponse()
        guard final.code == 226 || final.code == 250 else {
            throw FTPError.transferInterrupted("Server aborted transfer: \(final.code) \(final.message)")
        }
        if totalBytes > 0 && received != totalBytes {
            throw FTPError.transferInterrupted(
                "Incomplete download: received \(received) of \(totalBytes) bytes"
            )
        }
        try fh.close()
        try DownloadStaging.commit(to: localURL)
    }

    // MARK: - Upload

    public func upload(
        from localURL: URL,
        remotePath: String,
        resume: Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        if dedicatedToTransfers {
            do {
                try performUpload(from: localURL, remotePath: remotePath, resume: resume, progress: progress)
            } catch {
                abandonSession()
                throw error
            }
            return
        }
        let xfer = makeTransferClient()
        try await xfer.connect()
        do {
            try await xfer.performUpload(
                from: localURL, remotePath: remotePath, resume: resume, progress: progress
            )
            await xfer.disconnect()
        } catch {
            await xfer.disconnect()
            throw error
        }
    }

    private func performUpload(
        from localURL: URL,
        remotePath: String,
        resume: Bool,
        progress: @Sendable (Int64, Int64) -> Void
    ) throws {
        // Stream from disk — avoids loading the whole file into memory.
        let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
        let total = (attrs[.size] as? Int64) ?? 0
        let fh = try FileHandle(forReadingFrom: localURL)
        defer { try? fh.close() }

        let dataSock = try openDataConnection()
        defer { dataSock.close() }

        // Resume from partial remote bytes when asked and the server accepts REST.
        // REST goes right before STOR (after PASV/EPSV) — some servers reset the
        // restart marker on intervening commands.
        var startOffset: Int64 = 0
        if resume,
           let r = try? sendCommand("SIZE \(remotePath)"), r.code == 213,
           let remote = Int64(r.message.trimmingCharacters(in: .whitespaces)),
           remote > 0, total > 0, remote < total {
            let rest = try sendCommand("REST \(remote)")
            if rest.code == 350 {
                startOffset = remote
                try fh.seek(toOffset: UInt64(remote))
            }
        }

        let resp = try sendCommand("STOR \(remotePath)")
        if resp.code == 550 || resp.code == 553 {
            throw FTPError.permissionDenied(resp.message)
        }
        guard resp.code == 125 || resp.code == 150 else {
            throw FTPError.unexpectedResponse(resp.code, resp.message)
        }
        try secureDataConnection(dataSock)

        var sent = startOffset
        progress(sent, total)
        while true {
            try Task.checkCancellation()
            let chunk = try fh.read(upToCount: 65536) ?? Data()   // throwing read; see SFTPClient.upload
            if chunk.isEmpty { break }
            try dataSock.writeRaw(chunk)
            sent += Int64(chunk.count)
            progress(sent, total)
        }

        dataSock.close()   // signal EOF so the server finalizes the file

        // Require the server's success reply — a 426/451 (aborted) or 552
        // (disk full) here means the remote file is truncated and the upload
        // must be reported as failed, not "Done".
        let final = try readResponse()
        guard final.code == 226 || final.code == 250 else {
            throw FTPError.transferInterrupted("Server aborted transfer: \(final.code) \(final.message)")
        }

        // 226 isn't proof the server persisted every byte (buggy servers and
        // middleboxes ack short files). Verify via SIZE, mirroring the
        // download-side byte check; skipped when the server lacks SIZE.
        if total > 0,
           let r = try? sendCommand("SIZE \(remotePath)"), r.code == 213,
           let remoteSize = Int64(r.message.trimmingCharacters(in: .whitespaces)),
           remoteSize != total {
            throw FTPError.transferInterrupted(
                "Incomplete upload: server has \(remoteSize) of \(total) bytes"
            )
        }
    }

    // MARK: - Keep-Alive

    public func ping() async throws {
        try noop()
    }

    public func keepAlive() async {
        do {
            try noop()
        } catch {
            // The session is gone. Drop the socket so the next operation
            // reports "not connected" (and reconnects) straight away instead
            // of writing to, and waiting on, a dead connection.
            socket?.close()
            socket = nil
            tlsActive = false
        }
    }

    /// NOOP, answered with a 2xx. Anything else — a 421 the server sent as it
    /// timed us out, or a stray reply from an earlier command — means the
    /// session can't be trusted, and callers rely on that: the transfer queue
    /// pings a kept connection before its "does the file exist?" check, which
    /// would otherwise read a dead connection as "no such file" and overwrite
    /// without asking.
    private func noop() throws {
        let reply = try sendCommand("NOOP")
        guard (200..<300).contains(reply.code) else {
            abandonSession()
            throw FTPError.serverError(reply.code, reply.message)
        }
    }

    // MARK: - File Existence Check

    public func fileExists(at remotePath: String) async -> Bool {
        if let resp = try? sendCommand("SIZE \(remotePath)"), resp.code == 213 { return true }
        // SIZE only answers for files. Every other command here takes an
        // absolute path, so changing directory to ask about a folder is safe.
        if let resp = try? sendCommand("CWD \(remotePath)"), resp.code == 250 { return true }
        return false
    }

    public func remoteModifiedDate(at remotePath: String) async -> Date? {
        guard let resp = try? sendCommand("MDTM \(remotePath)"),
              resp.code == 213 else { return nil }
        // MDTM response format: "YYYYMMDDHHmmss" or "YYYYMMDDHHmmss.sss"
        let raw = resp.message.trimmingCharacters(in: .whitespaces)
        return Self.timestampFormatter().date(from: String(raw.prefix(14)))
    }

    public func setModifiedDate(_ date: Date, at remotePath: String) async {
        // RFC 3659 MFMT. Best-effort: servers without it just refuse.
        _ = try? sendCommand("MFMT \(Self.timestampFormatter().string(from: date)) \(remotePath)")
    }

    /// RFC 3659 timestamps (MDTM, MFMT): Gregorian, UTC. Without a fixed
    /// calendar and locale the formatter follows the user's settings, and a
    /// Buddhist or Japanese calendar reads "2024…" as a year five centuries
    /// out (and writes one).
    static func timestampFormatter() -> DateFormatter {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMddHHmmss"
        return fmt
    }

    public func createDirectory(at absolutePath: String) async throws {
        try await assertCode(sendSync("MKD \(absolutePath)"), expected: 257)
    }

    public func delete(at absolutePath: String, isDirectory: Bool) async throws {
        if isDirectory {
            try await assertCode(sendSync("RMD \(absolutePath)"), expected: 250)
        } else {
            try await assertCode(sendSync("DELE \(absolutePath)"), expected: 250)
        }
    }

    public func rename(from: String, to: String) async throws {
        try await assertCode(sendSync("RNFR \(from)"), expected: 350)
        try await assertCode(sendSync("RNTO \(to)"), expected: 250)
    }

    public func setPermissions(_ octal: Int, at absolutePath: String) async throws {
        let resp = try await sendSync("SITE CHMOD \(octal) \(absolutePath)")
        guard resp.code == 200 else { throw RemoteClientError.unsupported("SITE CHMOD") }
    }

    public func setOwnership(owner: String, group: String, at absolutePath: String) async throws {
        let arg = owner.isEmpty ? group : (group.isEmpty ? "\(owner):" : "\(owner):\(group)")
        let resp = try await sendSync("SITE CHOWN \(arg) \(absolutePath)")
        guard resp.code == 200 || resp.code == 250 else {
            throw RemoteClientError.unsupported("SITE CHOWN")
        }
    }

    // MARK: - Async Helpers

    private func sendSync(_ command: String) async throws -> FTPResponse {
        try sendCommand(command)
    }

    private func assertCode(_ resp: FTPResponse, expected: Int) throws {
        guard resp.code == expected else {
            throw FTPError.serverError(resp.code, resp.message)
        }
    }

    // MARK: - Control Channel (called on serialQ)

    @discardableResult
    private func sendCommand(_ command: String) throws -> FTPResponse {
        // Reject CR/LF/NUL anywhere in the command — protects against
        // injection via untrusted paths, filenames, usernames, or passwords.
        try RemotePath.validateCommand(command)
        guard let s = socket else { throw RemoteClientError.notConnected }
        try s.writeLine(command)
        return try readResponse()
    }

    private func readResponse() throws -> FTPResponse {
        do {
            return try readResponse(from: socket)
        } catch {
            // A reply we couldn't read in full (cancelled, timed out, garbled)
            // is still owed. Reading it as the answer to the next command would
            // leave every later reply one command behind, so drop the session:
            // the next operation reports "not connected" and the caller logs in
            // again.
            abandonSession()
            throw error
        }
    }

    private func readResponse(from socket: FTPSocket?) throws -> FTPResponse {
        guard let s = socket else { throw RemoteClientError.notConnected }

        // RFC 959 §4.2: a multi-line reply starts with `<code>-<text>` and ends
        // with `<code> <text>` (same code, space separator). Continuation lines
        // are anything in between, even if they begin with three digits — only
        // a `<code> ` prefix terminates the reply.
        let first = try s.readLine()
        guard first.count >= 4, let code = Int(first.prefix(3)) else {
            throw FTPError.unexpectedResponse(0, first)
        }
        let separator = first[first.index(first.startIndex, offsetBy: 3)]
        var lines = [String(first.dropFirst(4))]

        if separator == "-" {
            let terminator = "\(code) "
            while true {
                let line = try s.readLine()
                if line.hasPrefix(terminator) {
                    lines.append(String(line.dropFirst(4)))
                    break
                }
                lines.append(line)
            }
        }

        return FTPResponse(code: code, message: lines.joined(separator: "\n"))
    }

    // MARK: - Passive Data Connection

    private func openDataConnectionAndRun(command: String) throws -> Data {
        let dataSock = try openDataConnection()
        defer { dataSock.close() }

        let resp = try sendCommand(command)
        guard resp.code == 125 || resp.code == 150 else {
            throw FTPError.serverError(resp.code, resp.message)
        }
        var result = Data()
        do {
            try secureDataConnection(dataSock)
            while let chunk = try dataSock.readChunk() { result.append(chunk) }
        } catch {
            // The transfer's final reply is still to come; see readResponse.
            abandonSession()
            throw error
        }
        // A non-226 final reply means the listing was cut short — surface it
        // rather than silently showing a partial directory.
        let final = try readResponse()
        guard final.code == 226 || final.code == 250 else {
            throw FTPError.listingFailed("\(final.code) \(final.message)")
        }
        return result
    }

    /// Wrap an open data connection in TLS (FTPS only). Must run *after* the
    /// transfer command's preliminary 125/150 reply: servers don't answer the
    /// data-channel handshake until they've been told what the connection is
    /// for, so handshaking any earlier deadlocks.
    private func secureDataConnection(_ dataSock: FTPSocket) throws {
        if tlsActive { try startTLS(on: dataSock) }
    }

    /// Opens the (still plaintext) passive data connection; see
    /// `secureDataConnection` for the TLS step.
    private func openDataConnection() throws -> FTPSocket {
        // Try EPSV first (better NAT traversal, IPv6 compatible)
        if supportsEPSV != false, let sock = try? openEPSV() { return sock }
        return try openPASV()
    }

    private func openEPSV() throws -> FTPSocket {
        let resp = try sendCommand("EPSV")
        guard resp.code == 229 else {
            if Self.isUnknownCommand(resp.code) { supportsEPSV = false }
            throw FTPError.noPassiveAddress
        }

        // Parse "|||port|" from response text
        guard let portStr = resp.message.firstMatch(of: #/\|\|\|(\d+)\|/#)?.output.1,
              let port = Int(portStr) else {
            throw FTPError.noPassiveAddress
        }

        let sock = FTPSocket()
        try sock.connect(host: dataHost, port: port)
        return sock
    }

    /// Where data connections go: the address the control connection reached,
    /// not the hostname looked up again. With round-robin DNS a fresh lookup
    /// can pick a different server, which knows nothing of this session, and
    /// an unreachable IPv6 address would cost every data connection the full
    /// connect timeout before IPv4 was tried.
    private var dataHost: String {
        socket?.peerAddress ?? connection.host
    }

    private func openPASV() throws -> FTPSocket {
        let resp = try sendCommand("PASV")
        guard resp.code == 227 else { throw FTPError.noPassiveAddress }

        // Parse "(h1,h2,h3,h4,p1,p2)"
        guard let match = resp.message.firstMatch(of: #/\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)/#),
              let p1 = Int(match.output.5), let p2 = Int(match.output.6) else {
            throw FTPError.noPassiveAddress
        }

        let port = p1 * 256 + p2
        // Use the control-channel host (ignores server's PASV IP — common NAT workaround)
        let sock = FTPSocket()
        try sock.connect(host: dataHost, port: port)
        return sock
    }

}

// MARK: - Name encoding

/// FTP sends names as bytes, in whatever encoding the server's files use.
/// Most are UTF-8; older servers use Latin-1, Windows-1252, Shift-JIS and
/// the like. Reading those as Latin-1 (as this client once did) gave names
/// that went back out as different bytes, so the file couldn't be opened,
/// renamed or deleted, and one such name turned the rest of its folder into
/// mojibake.
///
/// Instead, valid UTF-8 is read as such, and each byte that isn't is kept as
/// the private-use character U+F700 + byte (U+F780...U+F7FF), which `encode`
/// turns back into that same byte. Names round-trip exactly, whatever the
/// server's encoding; the cost is that those bytes show as placeholder
/// glyphs. (A real name containing one of those private-use characters
/// would not survive, which is far less likely.)
public enum FTPNameEncoding {
    private static let escapeBase: UInt32 = 0xF700
    private static let escaped: ClosedRange<UInt32> = 0xF780...0xF7FF

    public static func decode<Bytes: Collection>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let bytes = Array(bytes)
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < bytes.count {
            let length = sequenceLength(bytes[index])
            if length > 0, index + length <= bytes.count,
               let decoded = String(bytes: bytes[index..<index + length], encoding: .utf8) {
                scalars.append(contentsOf: decoded.unicodeScalars)
                index += length
            } else {
                scalars.append(Unicode.Scalar(escapeBase + UInt32(bytes[index]))!)
                index += 1
            }
        }
        return String(scalars)
    }

    public static func encode(_ text: String) -> Data {
        var data = Data()
        for scalar in text.unicodeScalars {
            if escaped.contains(scalar.value) {
                data.append(UInt8(scalar.value - escapeBase))
            } else {
                data.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        return data
    }

    /// Length of the UTF-8 sequence `lead` starts, or 0 if it can't start one.
    private static func sequenceLength(_ lead: UInt8) -> Int {
        switch lead {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: return 2
        case 0xE0...0xEF: return 3
        case 0xF0...0xF4: return 4
        default:          return 0
        }
    }
}

// MARK: - Listing Parsers

/// Pure parsers for FTP directory listings, separated from the `FTPClient`
/// actor so they're unit-testable and can't touch connection state.
public enum FTPListingParser {

    // MARK: MLSD (machine-readable)

    public static func mlsdLine(_ line: String, basePath: String) -> FileItem? {
        // Format: "fact=value;fact=value; name"
        guard let spaceIdx = line.firstIndex(of: " ") else { return nil }
        let facts = String(line[line.startIndex ..< spaceIdx])
        let rawName = String(line[line.index(after: spaceIdx)...])
        guard let name = RemotePath.sanitizedFilename(rawName) else { return nil }

        var isDir     = false
        var isSymlink = false
        var size:       Int64?  = nil
        var modified:   Date?   = nil
        var perms:      String? = nil

        for fact in facts.components(separatedBy: ";") {
            let kv = fact.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "type":
                let v = String(kv[1]).lowercased()
                isDir     = v == "dir" || v == "cdir" || v == "pdir"
                // Spelled "OS.unix=symlink" or "OS.unix=slink[:<target>]",
                // depending on the server.
                isSymlink = v == "os.unix=symlink" || v.hasPrefix("os.unix=slink")
            case "size":    size     = Int64(kv[1])
            case "modify":  modified = mlsdDate(String(kv[1]))
            case "unix.mode": perms  = String(kv[1])
            default: break
            }
        }

        let path = basePath.hasSuffix("/") ? "\(basePath)\(name)" : "\(basePath)/\(name)"
        return FileItem(name: name, path: path, isDirectory: isDir, isSymlink: isSymlink,
                        size: size, modifiedDate: modified, permissions: perms)
    }

    public static func mlsdDate(_ s: String) -> Date? {
        let clean = String(s.prefix(14))
        guard clean.count == 14 else { return nil }
        var c = DateComponents()
        c.calendar  = Calendar(identifier: .gregorian)
        c.timeZone  = TimeZone(identifier: "UTC")
        c.year      = Int(clean.prefix(4))
        c.month     = Int(clean.dropFirst(4).prefix(2))
        c.day       = Int(clean.dropFirst(6).prefix(2))
        c.hour      = Int(clean.dropFirst(8).prefix(2))
        c.minute    = Int(clean.dropFirst(10).prefix(2))
        c.second    = Int(clean.dropFirst(12).prefix(2))
        return c.date
    }

    // MARK: LIST (UNIX ls -la)

    /// The lines of a listing, with line endings removed but nothing else:
    /// trailing spaces belong to the name on the line.
    static func lines(of data: Data) -> [String] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { line in FTPNameEncoding.decode(line.last == UInt8(ascii: "\r") ? line.dropLast() : line) }
            .filter { !$0.allSatisfy(\.isWhitespace) }
    }

    public static func listLine(_ line: String, basePath: String) -> FileItem? {
        unixListLine(line, basePath: basePath) ?? dosListLine(line, basePath: basePath)
    }

    private static let months = ["Jan","Feb","Mar","Apr","May","Jun",
                                 "Jul","Aug","Sep","Oct","Nov","Dec"]

    /// `ls -l` style: "drwxr-xr-x  2 user group  4096 Jan 15 10:30 name".
    /// The group column is missing on some servers. The name is the rest of
    /// the line after the single space following the date, taken as is.
    private static func unixListLine(_ line: String, basePath: String) -> FileItem? {
        // Fields up to and including the date, with where each one ends.
        var fields: [(text: Substring, end: String.Index)] = []
        var index = line.startIndex
        while fields.count < 9, index < line.endIndex {
            while index < line.endIndex, line[index] == " " { index = line.index(after: index) }
            let start = index
            while index < line.endIndex, line[index] != " " { index = line.index(after: index) }
            if start < index { fields.append((line[start..<index], index)) }
        }
        // The month comes after "perms links owner [group] size".
        guard let month = [5, 4].first(where: { $0 + 2 < fields.count && months.contains(String(fields[$0].text)) }),
              Int(fields[month + 1].text) != nil else { return nil }

        let perms     = String(fields[0].text)
        let isDir     = perms.hasPrefix("d")
        let isSymlink = perms.hasPrefix("l")
        let dateEnd   = fields[month + 2].end
        guard dateEnd < line.endIndex else { return nil }
        var rawName = String(line[line.index(after: dateEnd)...])
        var symlinkTarget: String? = nil
        if isSymlink, let arrow = rawName.range(of: " -> ") {
            symlinkTarget = String(rawName[arrow.upperBound...])
            rawName = String(rawName[..<arrow.lowerBound])
        }
        guard let name = RemotePath.sanitizedFilename(rawName) else { return nil }

        return FileItem(
            name: name,
            path: RemotePath.join(basePath, name),
            isDirectory: isDir,
            isSymlink: isSymlink,
            symlinkTarget: symlinkTarget.flatMap(RemotePath.sanitizedFilename),
            size: Int64(fields[month - 1].text),
            modifiedDate: listDate(String(fields[month].text), String(fields[month + 1].text),
                                   String(fields[month + 2].text)),
            permissions: perms,
            owner: String(fields[2].text),
            group: month == 5 ? String(fields[3].text) : nil
        )
    }

    /// IIS / Windows style: "01-15-24  10:30AM       <DIR>          name"
    /// or "12-01-2023  01:05PM             1234 name" (month first).
    private static func dosListLine(_ line: String, basePath: String) -> FileItem? {
        guard let match = line.wholeMatch(
            of: #/(\d{2})-(\d{2})-(\d{2}|\d{4}) +(\d{1,2}):(\d{2})([AP]M) +(<DIR>|\d+) +(.+)/#
        ) else { return nil }
        let out = match.output
        guard let name = RemotePath.sanitizedFilename(String(out.8)) else { return nil }
        var year = Int(out.3) ?? 0
        if out.3.count == 2 { year += year < 70 ? 2000 : 1900 }
        var hour = (Int(out.4) ?? 0) % 12
        if out.6 == "PM" { hour += 12 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let modified = calendar.date(from: DateComponents(
            year: year, month: Int(out.1), day: Int(out.2), hour: hour, minute: Int(out.5)
        ))
        let isDir = out.7 == "<DIR>"
        return FileItem(
            name: name,
            path: RemotePath.join(basePath, name),
            isDirectory: isDir,
            size: isDir ? nil : Int64(out.7),
            modifiedDate: modified
        )
    }

    /// `ls -l` carries no timezone, so we interpret it as UTC for consistency
    /// with MLSD/MDTM (which are UTC) instead of the client's local zone.
    public static func listDate(_ month: String, _ day: String, _ yearOrTime: String, now: Date = Date()) -> Date? {
        guard let mIdx = months.firstIndex(of: month) else { return nil }
        var c = DateComponents()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        c.timeZone   = TimeZone(identifier: "UTC")
        c.month = mIdx + 1
        c.day   = Int(day)
        guard yearOrTime.contains(":") else {
            c.year = Int(yearOrTime)
            return cal.date(from: c)
        }
        // A time instead of a year means "within roughly the last six
        // months". Assume this year, unless that lands in the future — then
        // it's last year's (e.g. "Dec 28" read in early January). A day of
        // slack absorbs server clocks and time zones ahead of ours.
        let t = yearOrTime.components(separatedBy: ":")
        c.hour   = Int(t[0])
        c.minute = t.count > 1 ? Int(t[1]) : 0
        c.year   = cal.component(.year, from: now)
        guard let date = cal.date(from: c) else { return nil }
        if date > now.addingTimeInterval(24 * 60 * 60) {
            c.year = cal.component(.year, from: now) - 1
            return cal.date(from: c)
        }
        return date
    }
}
