// FTPClient.swift
// Full FTP / FTPS implementation using POSIX sockets + SecureTransport.
// Control channel: one persistent connection per session.
// Data transfers: each spawns a separate FTP session to allow independent cancellation
// and avoid blocking the main control channel.

import Foundation
import Darwin
import Security

// MARK: - Errors

enum FTPError: LocalizedError {
    case connectionFailed(String)
    case unexpectedResponse(Int, String)
    case authFailed
    case permissionDenied(String)
    case tlsSetupFailed(String)
    case noPassiveAddress
    case transferInterrupted(String)
    case listingFailed(String)
    case serverError(Int, String)

    var errorDescription: String? {
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
        }
    }
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

        // Bound blocking reads so the transfer loop can check cancellation and
        // enforce an idle deadline. Sends stay blocking (cancellation is checked
        // between chunks), which avoids SecureTransport's SSLWrite would-block
        // complications.
        var tv = timeval(tv_sec: Int(Self.recvTick), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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

    func startTLS(serverName: String) throws {
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw FTPError.tlsSetupFailed("SSLCreateContext failed")
        }

        // C-function-pointer callbacks: non-capturing; fd is passed via the `connection` pointer.
        let readFn: SSLReadFunc = { connection, data, dataLength -> OSStatus in
            let fd = Int32(Int(bitPattern: connection))
            let n  = Darwin.recv(fd, data, dataLength.pointee, 0)
            if n > 0  { dataLength.pointee = n; return noErr }
            if n == 0 { dataLength.pointee = 0; return OSStatus(errSSLClosedGraceful) }
            dataLength.pointee = 0
            return (errno == EAGAIN || errno == EWOULDBLOCK)
                ? OSStatus(errSSLWouldBlock) : OSStatus(errSecIO)
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
                try Self.evaluateServerTrust(ctx, serverName: serverName)
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

    private static func evaluateServerTrust(_ ctx: SSLContext, serverName: String) throws {
        var trust: SecTrust?
        let copyStatus = SSLCopyPeerTrust(ctx, &trust)
        guard copyStatus == errSecSuccess, let serverTrust = trust else {
            throw FTPError.tlsSetupFailed("Could not retrieve server certificate (status \(copyStatus))")
        }

        // Bind hostname into the trust evaluation policy so CN/SAN match.
        let policy = SecPolicyCreateSSL(true, serverName as CFString)
        SecTrustSetPolicies(serverTrust, policy)

        var cfError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &cfError) else {
            let detail = cfError.map { CFErrorCopyDescription($0) as String } ?? "untrusted"
            throw FTPError.tlsSetupFailed("Server certificate rejected: \(detail)")
        }
    }

    // MARK: Write

    func writeLine(_ s: String) throws {
        guard let data = (s + "\r\n").data(using: .utf8) else { return }
        try writeRaw(data)
    }

    func writeRaw(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            // Sends stay blocking, but bail promptly if the transfer is cancelled.
            if Task.isCancelled { throw CancellationError() }
            let count = data.count - offset
            let written: Int
            if let ctx = ssl {
                var processed = count
                let status = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
                    SSLWrite(ctx, ptr.baseAddress!.advanced(by: offset), count, &processed)
                }
                if status != noErr { throw FTPError.transferInterrupted("SSL write \(status)") }
                written = processed
            } else {
                written = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
                    Darwin.send(fd, ptr.baseAddress!.advanced(by: offset), count, 0)
                }
                if written <= 0 { throw FTPError.transferInterrupted("Socket write error") }
            }
            offset += written
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
        return String(data: line, encoding: .utf8) ?? ""
    }

    /// Read a chunk of data. Returns nil when the remote side closes the connection.
    func readChunk(maxBytes: Int = 65536) throws -> Data? {
        var tmp = [UInt8](repeating: 0, count: maxBytes)
        let n = try readAvailable(into: &tmp, max: maxBytes)
        return n == 0 ? nil : Data(tmp[0 ..< n])
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

actor FTPClient: RemoteClient {

    private let connection: Connection
    private let password: String
    private var socket: FTPSocket?
    private var tlsActive = false

    // FTP I/O here is blocking. Run this actor on a dedicated serial queue (a
    // real thread) instead of the Swift concurrency cooperative pool, so a slow
    // or concurrent transfer can't tie up a shared pool thread and stall every
    // other async task in the app.
    private let ioQueue = DispatchSerialQueue(label: "com.teleport.ftp.io")
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        ioQueue.asUnownedSerialExecutor()
    }

    init(connection: Connection, password: String) {
        self.connection = connection
        self.password   = password
    }

    // No `deinit { socket?.close() }` — actor-isolated state cannot be
    // touched from a non-isolated deinit. Callers must `await disconnect()`.

    // MARK: - Connect

    func connect() async throws {
        try connectSync()
    }

    private func connectSync() throws {
        // Reconnect-safe: drop any previous socket and, critically, reset
        // `tlsActive`. If it stayed true from a dead FTPS session, the AUTH TLS
        // upgrade below would be skipped and credentials would go out in
        // plaintext on the new socket.
        socket?.close()
        socket = nil
        tlsActive = false

        let sock = FTPSocket()

        if connection.connectionProtocol == .ftps && connection.port == 990 {
            // Implicit FTPS: TLS from the start
            try sock.connect(host: connection.host, port: connection.port)
            try sock.startTLS(serverName: connection.host)
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
            try sock.startTLS(serverName: connection.host)
            tlsActive = true

            // RFC 4217: PBSZ then PROT — without PROT P the data channel is plaintext.
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

    func disconnect() async {
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

    func listDirectory(at absolutePath: String) async throws -> [FileItem] {
        try listSync(path: absolutePath)
    }

    private func listSync(path: String) throws -> [FileItem] {
        // Prefer MLSD (machine-readable); fall back to LIST
        if let items = try? mlsdSync(path: path) { return items }
        return try listRawSync(path: path)
    }

    private func mlsdSync(path: String) throws -> [FileItem] {
        let data = try openDataConnectionAndRun(command: "MLSD \(path)")
        guard let text = String(data: data, encoding: .utf8) else { throw FTPError.listingFailed("Non-UTF8") }
        return text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { FTPListingParser.mlsdLine($0, basePath: path) }
            .filter { $0.name != "." && $0.name != ".." }
    }

    private func listRawSync(path: String) throws -> [FileItem] {
        let data = try openDataConnectionAndRun(command: "LIST \(path)")
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FTPError.listingFailed("Could not decode listing")
        }
        return text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { FTPListingParser.listLine($0, basePath: path) }
            .filter { $0.name != "." && $0.name != ".." }
    }

    // MARK: - Download

    func download(
        remotePath: String,
        to localURL: URL,
        resume: Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let xfer = FTPClient(connection: connection, password: password)
        try await xfer.connect()
        do {
            try await xfer.performDownload(
                remotePath: remotePath, to: localURL, resume: resume, progress: progress
            )
            await xfer.disconnect()
        } catch {
            await xfer.disconnect()
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

        // Resume from partial local bytes when asked and the server accepts REST.
        // REST is sent after PASV/EPSV, immediately before RETR — some servers
        // reset the restart marker on intervening commands.
        var startOffset: Int64 = 0
        if resume,
           let existing = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]) as? Int64,
           existing > 0, totalBytes > 0, existing < totalBytes {
            let rest = try sendCommand("REST \(existing)")
            if rest.code == 350 { startOffset = existing }   // else fall back to full
        }

        // O_NOFOLLOW; only truncate on a clean (non-resume) start.
        let fh = try Self.openForWriting(at: localURL, truncate: startOffset == 0)
        defer { try? fh.close() }
        if startOffset > 0 { try fh.seek(toOffset: UInt64(startOffset)) }

        let resp = try sendCommand("RETR \(remotePath)")
        if resp.code == 550 {
            throw FTPError.permissionDenied(resp.message)
        }
        guard resp.code == 125 || resp.code == 150 else {
            throw FTPError.unexpectedResponse(resp.code, resp.message)
        }

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
            throw FTPError.transferInterrupted(
                "Could not open destination: \(String(cString: strerror(err)))"
            )
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // MARK: - Upload

    func upload(
        from localURL: URL,
        remotePath: String,
        resume: Bool,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let xfer = FTPClient(connection: connection, password: password)
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

        var sent = startOffset
        progress(sent, total)
        while true {
            try Task.checkCancellation()
            let chunk = fh.readData(ofLength: 65536)
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

    func keepAlive() async {
        _ = try? sendCommand("NOOP")
    }

    // MARK: - File Existence Check

    func fileExists(at remotePath: String) async -> Bool {
        let resp = try? sendCommand("SIZE \(remotePath)")
        return resp?.code == 213
    }

    func remoteModifiedDate(at remotePath: String) async -> Date? {
        guard let resp = try? sendCommand("MDTM \(remotePath)"),
              resp.code == 213 else { return nil }
        // MDTM response format: "YYYYMMDDHHmmss" or "YYYYMMDDHHmmss.sss"
        let raw = resp.message.trimmingCharacters(in: .whitespaces)
        let dateStr = String(raw.prefix(14))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.date(from: dateStr)
    }

    func setModifiedDate(_ date: Date, at remotePath: String) async {
        // RFC 3659 MFMT. Best-effort: servers without it just refuse.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        _ = try? sendCommand("MFMT \(fmt.string(from: date)) \(remotePath)")
    }

    func createDirectory(at absolutePath: String) async throws {
        try await assertCode(sendSync("MKD \(absolutePath)"), expected: 257)
    }

    func delete(at absolutePath: String, isDirectory: Bool) async throws {
        if isDirectory {
            try await assertCode(sendSync("RMD \(absolutePath)"), expected: 250)
        } else {
            try await assertCode(sendSync("DELE \(absolutePath)"), expected: 250)
        }
    }

    func rename(from: String, to: String) async throws {
        try await assertCode(sendSync("RNFR \(from)"), expected: 350)
        try await assertCode(sendSync("RNTO \(to)"), expected: 250)
    }

    func setPermissions(_ octal: Int, at absolutePath: String) async throws {
        let resp = try await sendSync("SITE CHMOD \(octal) \(absolutePath)")
        guard resp.code == 200 else { throw RemoteClientError.unsupported("SITE CHMOD") }
    }

    func setOwnership(owner: String, group: String, at absolutePath: String) async throws {
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
        while let chunk = try dataSock.readChunk() { result.append(chunk) }
        // A non-226 final reply means the listing was cut short — surface it
        // rather than silently showing a partial directory.
        let final = try readResponse()
        guard final.code == 226 || final.code == 250 else {
            throw FTPError.listingFailed("\(final.code) \(final.message)")
        }
        return result
    }

    private func openDataConnection() throws -> FTPSocket {
        // Try EPSV first (better NAT traversal, IPv6 compatible)
        if let sock = try? openEPSV() { return sock }
        return try openPASV()
    }

    private func openEPSV() throws -> FTPSocket {
        let resp = try sendCommand("EPSV")
        guard resp.code == 229 else { throw FTPError.noPassiveAddress }

        // Parse "|||port|" from response text
        guard let portStr = resp.message.firstMatch(of: #/\|\|\|(\d+)\|/#)?.output.1,
              let port = Int(portStr) else {
            throw FTPError.noPassiveAddress
        }

        let sock = FTPSocket()
        try sock.connect(host: connection.host, port: port)
        if tlsActive { try sock.startTLS(serverName: connection.host) }
        return sock
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
        try sock.connect(host: connection.host, port: port)
        if tlsActive { try sock.startTLS(serverName: connection.host) }
        return sock
    }

}

// MARK: - Listing Parsers

/// Pure parsers for FTP directory listings, separated from the `FTPClient`
/// actor so they're unit-testable and can't touch connection state.
enum FTPListingParser {

    // MARK: MLSD (machine-readable)

    static func mlsdLine(_ line: String, basePath: String) -> FileItem? {
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
                isSymlink = v == "os.unix=symlink"
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

    static func mlsdDate(_ s: String) -> Date? {
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

    static func listLine(_ line: String, basePath: String) -> FileItem? {
        // "drwxr-xr-x  2 user group  4096 Jan 15 10:30 name"
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 9 else { return nil }

        let perms     = parts[0]
        let isDir     = perms.hasPrefix("d")
        let isSymlink = perms.hasPrefix("l")
        let size      = Int64(parts[4])

        // Reconstruct name (may contain spaces); strip symlink arrow.
        var rawName = parts[8...].joined(separator: " ")
        var symlinkTarget: String? = nil
        if let arrow = rawName.range(of: " -> ") {
            symlinkTarget = String(rawName[arrow.upperBound...])
            rawName = String(rawName[..<arrow.lowerBound])
        }
        guard let name = RemotePath.sanitizedFilename(rawName) else { return nil }

        let modified = listDate(parts[5], parts[6], parts[7])
        let path = basePath.hasSuffix("/") ? "\(basePath)\(name)" : "\(basePath)/\(name)"

        return FileItem(
            name: name,
            path: path,
            isDirectory: isDir,
            isSymlink: isSymlink,
            symlinkTarget: symlinkTarget.flatMap(RemotePath.sanitizedFilename),
            size: size,
            modifiedDate: modified,
            permissions: perms,
            owner: parts[2],
            group: parts[3]
        )
    }

    /// `ls -l` carries no timezone, so we interpret it as UTC for consistency
    /// with MLSD/MDTM (which are UTC) instead of the client's local zone.
    static func listDate(_ month: String, _ day: String, _ yearOrTime: String) -> Date? {
        let months = ["Jan","Feb","Mar","Apr","May","Jun",
                      "Jul","Aug","Sep","Oct","Nov","Dec"]
        guard let mIdx = months.firstIndex(of: month) else { return nil }
        var c = DateComponents()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        c.timeZone   = TimeZone(identifier: "UTC")
        c.month = mIdx + 1
        c.day   = Int(day)
        if yearOrTime.contains(":") {
            let t = yearOrTime.components(separatedBy: ":")
            c.hour   = Int(t[0])
            c.minute = t.count > 1 ? Int(t[1]) : 0
            c.year   = cal.component(.year, from: Date())
        } else {
            c.year = Int(yearOrTime)
        }
        return cal.date(from: c)
    }
}
