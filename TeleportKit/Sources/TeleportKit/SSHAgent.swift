import Foundation
import Darwin
import NIOCore
import NIOSSH

/// Client for a running `ssh-agent` (the socket in `SSH_AUTH_SOCK`): lists
/// the keys it holds and asks it to sign with them. The private keys never
/// leave the agent.
///
/// I/O is blocking with a timeout, one short-lived connection per request.
public struct SSHAgent: Sendable {

    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// The agent named by `SSH_AUTH_SOCK`, if there is one. macOS sets this
    /// for apps launched from the Finder as well as from a shell.
    public static var fromEnvironment: SSHAgent? {
        from(environment: ProcessInfo.processInfo.environment)
    }

    static func from(environment: [String: String]) -> SSHAgent? {
        guard let path = environment["SSH_AUTH_SOCK"], !path.isEmpty else { return nil }
        return SSHAgent(socketPath: path)
    }

    public enum Failure: LocalizedError {
        case unreachable(String)
        case refused
        case malformedReply

        public var errorDescription: String? {
            switch self {
            case .unreachable(let why): return "Could not reach ssh-agent: \(why)"
            case .refused:              return "ssh-agent refused the request"
            case .malformedReply:       return "ssh-agent sent a reply that couldn't be understood"
            }
        }
    }

    struct Identity: Equatable {
        /// The public key in SSH wire form: `string algorithm` + key data.
        let keyBlob: Data
        let comment: String
        let algorithm: String
    }

    // MARK: - Requests

    private enum Message {
        static let failure: UInt8 = 5
        static let requestIdentities: UInt8 = 11
        static let identitiesAnswer: UInt8 = 12
        static let signRequest: UInt8 = 13
        static let signResponse: UInt8 = 14
    }

    func identities() throws -> [Identity] {
        var reply = try request(type: Message.requestIdentities, payload: ByteBuffer())
        guard reply.readInteger(as: UInt8.self) == Message.identitiesAnswer,
              let count = reply.readInteger(as: UInt32.self) else { throw Failure.malformedReply }
        var identities: [Identity] = []
        for _ in 0..<count {
            guard let blob = reply.readSSHString(), let comment = reply.readSSHString() else {
                throw Failure.malformedReply
            }
            var typed = blob
            guard let algorithm = typed.readSSHString() else { throw Failure.malformedReply }
            identities.append(Identity(
                keyBlob: Data(blob.readableBytesView),
                comment: String(buffer: comment),
                algorithm: String(buffer: algorithm)
            ))
        }
        return identities
    }

    /// Signature blob (`string algorithm` + signature data) over `data` made
    /// with the key identified by `keyBlob`.
    func sign(_ data: Data, with keyBlob: Data) throws -> Data {
        var payload = ByteBuffer()
        payload.writeSSHString(keyBlob)
        payload.writeSSHString(data)
        payload.writeInteger(UInt32(0))   // flags
        var reply = try request(type: Message.signRequest, payload: payload)
        guard reply.readInteger(as: UInt8.self) == Message.signResponse,
              let signature = reply.readSSHString() else { throw Failure.refused }
        return Data(signature.readableBytesView)
    }

    // MARK: - Keys to offer

    /// Algorithms SwiftNIO SSH can negotiate here, best first. RSA goes last:
    /// it can only be used with a SHA-1 signature, which current servers
    /// refuse. Hardware-backed (`sk-…`) keys and certificates are left out.
    private static let usableAlgorithms = [
        "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa",
    ]

    /// The agent's keys worth offering, in offer order, at most `limit` —
    /// servers allow only a handful of tries per connection. Empty when the
    /// agent can't be reached: an unavailable agent is not an error, there
    /// are simply no keys from it.
    func usableIdentities(limit: Int) -> [Identity] {
        guard let all = try? identities() else { return [] }
        let usable = all.filter { Self.usableAlgorithms.contains($0.algorithm) }
        let ordered = usable.filter { $0.algorithm != "ssh-rsa" } + usable.filter { $0.algorithm == "ssh-rsa" }
        return Array(ordered.prefix(limit))
    }

    func privateKeys(limit: Int) -> [NIOSSHPrivateKey] {
        usableIdentities(limit: limit).compactMap { identity in
            switch identity.algorithm {
            case Ed25519Algorithm.name:   return NIOSSHPrivateKey(custom: AgentPrivateKey<Ed25519Algorithm>(agent: self, keyBlob: identity.keyBlob))
            case ECDSAP256Algorithm.name: return NIOSSHPrivateKey(custom: AgentPrivateKey<ECDSAP256Algorithm>(agent: self, keyBlob: identity.keyBlob))
            case ECDSAP384Algorithm.name: return NIOSSHPrivateKey(custom: AgentPrivateKey<ECDSAP384Algorithm>(agent: self, keyBlob: identity.keyBlob))
            case ECDSAP521Algorithm.name: return NIOSSHPrivateKey(custom: AgentPrivateKey<ECDSAP521Algorithm>(agent: self, keyBlob: identity.keyBlob))
            case RSAAlgorithm.name:       return NIOSSHPrivateKey(custom: AgentPrivateKey<RSAAlgorithm>(agent: self, keyBlob: identity.keyBlob))
            default:                      return nil
            }
        }
    }

    // MARK: - Transport

    /// Signing can involve the user (Touch ID, a confirmation dialog).
    private static let timeoutSeconds = 30
    private static let maxReplySize = 1 << 20

    private func request(type: UInt8, payload: ByteBuffer) throws -> ByteBuffer {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.unreachable(String(cString: strerror(errno))) }
        defer { Darwin.close(fd) }

        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: Self.timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.count < capacity else { throw Failure.unreachable("socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { throw Failure.unreachable(String(cString: strerror(errno))) }

        var message = ByteBuffer()
        message.writeInteger(UInt32(1 + payload.readableBytes))
        message.writeInteger(type)
        message.writeImmutableBuffer(payload)
        try Self.sendAll(fd, Array(message.readableBytesView))

        let header = try Self.receive(fd, count: 4)
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard length > 0, length <= Self.maxReplySize else { throw Failure.malformedReply }
        let reply = ByteBuffer(bytes: try Self.receive(fd, count: length))
        if reply.getInteger(at: reply.readerIndex, as: UInt8.self) == Message.failure { throw Failure.refused }
        return reply
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8]) throws {
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Failure.unreachable(String(cString: strerror(errno))) }
            sent += n
        }
    }

    private static func receive(_ fd: Int32, count: Int) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Failure.unreachable(n == 0 ? "connection closed" : String(cString: strerror(errno))) }
            got += n
        }
        return buffer
    }
}

// MARK: - Agent-backed keys

// SwiftNIO SSH identifies a custom key type by static strings, so each SSH
// algorithm needs a type of its own. One generic implementation covers them
// all: the key and signature bodies are passed through exactly as the agent
// produced them, so nothing here needs to understand the cryptography.

protocol AgentKeyAlgorithm { static var name: String { get } }
enum Ed25519Algorithm: AgentKeyAlgorithm   { static let name = "ssh-ed25519" }
enum ECDSAP256Algorithm: AgentKeyAlgorithm { static let name = "ecdsa-sha2-nistp256" }
enum ECDSAP384Algorithm: AgentKeyAlgorithm { static let name = "ecdsa-sha2-nistp384" }
enum ECDSAP521Algorithm: AgentKeyAlgorithm { static let name = "ecdsa-sha2-nistp521" }
enum RSAAlgorithm: AgentKeyAlgorithm       { static let name = "ssh-rsa" }

private struct AgentKeyError: Error {}

/// Everything after the leading `string algorithm` of a key or signature blob.
private func bodyOfBlob(_ blob: Data) -> Data {
    var buffer = ByteBuffer(data: blob)
    _ = buffer.readSSHString()
    return Data(buffer.readableBytesView)
}

struct AgentPrivateKey<Algorithm: AgentKeyAlgorithm>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Algorithm.name }

    let agent: SSHAgent
    let keyBlob: Data

    var publicKey: NIOSSHPublicKeyProtocol {
        AgentPublicKey<Algorithm>(body: bodyOfBlob(keyBlob))
    }

    /// Called on the connection's event loop; blocks it for the agent round
    /// trip (normally microseconds, longer if the agent asks the user).
    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        AgentSignature<Algorithm>(body: bodyOfBlob(try agent.sign(Data(data), with: keyBlob)))
    }
}

struct AgentPublicKey<Algorithm: AgentKeyAlgorithm>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Algorithm.name }

    let body: Data
    var rawRepresentation: Data { body }

    // Only ever used to prove our own identity, never to check someone else's.
    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool { false }

    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeBytes(body) }

    static func read(from buffer: inout ByteBuffer) throws -> Self { throw AgentKeyError() }
}

struct AgentSignature<Algorithm: AgentKeyAlgorithm>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Algorithm.name }

    let body: Data
    var rawRepresentation: Data { body }

    func write(to buffer: inout ByteBuffer) -> Int { buffer.writeBytes(body) }

    static func read(from buffer: inout ByteBuffer) throws -> Self { throw AgentKeyError() }
}

extension ByteBuffer {
    /// SSH wire `string`: a uint32 length followed by the bytes.
    mutating func writeSSHString(_ data: Data) {
        writeInteger(UInt32(data.count))
        writeBytes(data)
    }
}
