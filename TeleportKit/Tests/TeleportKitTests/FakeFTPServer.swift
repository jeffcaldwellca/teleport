import Foundation
import Darwin

/// Minimal scripted FTP server on 127.0.0.1 for unit tests: just enough of the
/// control/data dialogue to drive `FTPClient` through login, keep-alive and
/// `RETR`, with knobs for the failure modes under test.
final class FakeFTPServer: @unchecked Sendable {

    enum Retr {
        /// Reply 550 to RETR without sending any data.
        case refuse
        /// Send `data` (from the REST offset) on the data channel, then `finalReply`.
        case send(Data, finalReply: String)
    }

    let port: Int
    private let listenFD: Int32
    private let lock = NSLock()
    private var _retr: Retr = .refuse
    private var _reportedSize: Int?
    private var _dropControlAfterLogin = false
    private var _commands: [String] = []
    private var _supportsEPSV = true
    private var _mlsdListing: String?
    private var _listReply: (String) -> String? = { _ in nil }

    /// Every command line received, across all connections.
    var commands: [String] { lock.withLock { _commands } }

    /// When false, EPSV answers 500 and the client must fall back to PASV.
    var supportsEPSV: Bool {
        get { lock.withLock { _supportsEPSV } }
        set { lock.withLock { _supportsEPSV = newValue } }
    }

    /// Listing sent for MLSD; nil answers 500 (command not understood).
    var mlsdListing: String? {
        get { lock.withLock { _mlsdListing } }
        set { lock.withLock { _mlsdListing = newValue } }
    }

    /// Listing sent for `LIST <argument>` (e.g. "-a /dir" or "/dir"); nil answers 550.
    var listReply: (String) -> String? {
        get { lock.withLock { _listReply } }
        set { lock.withLock { _listReply = newValue } }
    }

    var retr: Retr {
        get { lock.withLock { _retr } }
        set { lock.withLock { _retr = newValue } }
    }

    /// Value returned for `SIZE`; nil answers 550.
    var reportedSize: Int? {
        get { lock.withLock { _reportedSize } }
        set { lock.withLock { _reportedSize = newValue } }
    }

    /// Close the control connection right after the login sequence completes.
    var dropControlAfterLogin: Bool {
        get { lock.withLock { _dropControlAfterLogin } }
        set { lock.withLock { _dropControlAfterLogin = newValue } }
    }

    init() throws {
        (listenFD, port) = try Self.listen()
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let conn = Darwin.accept(fd, nil, nil)
                guard conn >= 0 else { return }
                Self.noSigPipe(conn)
                Thread.detachNewThread { self?.serve(conn) }
            }
        }
    }

    func stop() { Darwin.close(listenFD) }

    // MARK: - Control connection

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        Self.send(fd, "220 fake")
        var dataListener: Int32 = -1
        var restOffset = 0
        defer { if dataListener >= 0 { Darwin.close(dataListener) } }

        while let line = Self.readLine(fd) {
            lock.withLock { _commands.append(line) }
            let argument = line.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let verb = line.split(separator: " ").first.map { $0.uppercased() } ?? ""
            switch verb {
            case "USER": Self.send(fd, "230 ok")
            case "TYPE", "NOOP": Self.send(fd, "200 ok")
            case "OPTS":
                Self.send(fd, "200 ok")
                if dropControlAfterLogin { return }
            case "SIZE":
                Self.send(fd, reportedSize.map { "213 \($0)" } ?? "550 no size")
            case "EPSV" where !supportsEPSV:
                Self.send(fd, "500 EPSV not understood")
            case "PASV":
                guard let (listener, dataPort) = try? Self.listen() else { return }
                if dataListener >= 0 { Darwin.close(dataListener) }
                dataListener = listener
                Self.send(fd, "227 Entering Passive Mode (127,0,0,1,\(dataPort / 256),\(dataPort % 256))")
            case "MLSD":
                if let listing = mlsdListing {
                    Self.sendOverData(listing, control: fd, listener: dataListener)
                } else {
                    Self.send(fd, "500 MLSD not understood")
                }
            case "LIST":
                if let listing = listReply(argument) {
                    Self.sendOverData(listing, control: fd, listener: dataListener)
                } else {
                    Self.send(fd, "550 no such directory")
                }
            case "EPSV":
                guard let (listener, dataPort) = try? Self.listen() else { return }
                if dataListener >= 0 { Darwin.close(dataListener) }
                dataListener = listener
                Self.send(fd, "229 Entering Extended Passive Mode (|||\(dataPort)|)")
            case "REST":
                restOffset = Int(line.dropFirst(5)) ?? 0
                Self.send(fd, "350 ok")
            case "RETR":
                switch retr {
                case .refuse:
                    Self.send(fd, "550 denied")
                case .send(let data, let finalReply):
                    Self.send(fd, "150 opening")
                    let dataFD = Darwin.accept(dataListener, nil, nil)
                    if dataFD >= 0 {
                        Self.noSigPipe(dataFD)
                        let body = Array(data.dropFirst(restOffset))
                        _ = Darwin.send(dataFD, body, body.count, 0)
                        Darwin.close(dataFD)
                    }
                    Self.send(fd, finalReply)
                }
                restOffset = 0
            case "QUIT":
                Self.send(fd, "221 bye")
                return
            default:
                Self.send(fd, "502 not implemented")
            }
        }
    }

    private static func sendOverData(_ text: String, control fd: Int32, listener: Int32) {
        send(fd, "150 opening")
        let dataFD = Darwin.accept(listener, nil, nil)
        if dataFD >= 0 {
            noSigPipe(dataFD)
            let body = Array(text.utf8)
            _ = Darwin.send(dataFD, body, body.count, 0)
            Darwin.close(dataFD)
        }
        send(fd, "226 done")
    }

    // MARK: - Socket helpers

    private static func listen() throws -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Bool in
                Darwin.bind(fd, sa, len) == 0 && Darwin.listen(fd, 8) == 0 && getsockname(fd, sa, &len) == 0
            }
        }
        guard bound else {
            Darwin.close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        return (fd, Int(UInt16(bigEndian: addr.sin_port)))
    }

    private static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func send(_ fd: Int32, _ line: String) {
        let bytes = Array((line + "\r\n").utf8)
        _ = Darwin.send(fd, bytes, bytes.count, 0)
    }

    private static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while Darwin.recv(fd, &byte, 1, 0) == 1 {
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            if byte != UInt8(ascii: "\r") { bytes.append(byte) }
        }
        return nil
    }
}
