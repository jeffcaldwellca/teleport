import XCTest
import Darwin
@testable import TeleportKit

/// A scripted ssh-agent on a Unix socket: answers the two requests the
/// client makes and records what it was asked to sign.
private final class FakeSSHAgent: @unchecked Sendable {
    let socketPath: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var _identities: [(blob: Data, comment: String)] = []
    private var _signature: Data? = Data()
    private var _signRequests: [(key: Data, data: Data)] = []

    var identities: [(blob: Data, comment: String)] {
        get { lock.withLock { _identities } }
        set { lock.withLock { _identities = newValue } }
    }
    /// Signature blob to return; nil answers SSH_AGENT_FAILURE.
    var signature: Data? {
        get { lock.withLock { _signature } }
        set { lock.withLock { _signature = newValue } }
    }
    var signRequests: [(key: Data, data: Data)] { lock.withLock { _signRequests } }

    init() throws {
        socketPath = "/tmp/tp-agent-\(UUID().uuidString.prefix(8)).sock"
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8.prefix(raw.count - 1)))
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 && Darwin.listen(listenFD, 8) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRNOTAVAIL) }
        let fd = listenFD
        Thread.detachNewThread { [weak self] in
            while true {
                let conn = Darwin.accept(fd, nil, nil)
                guard conn >= 0 else { return }
                self?.serve(conn)
                Darwin.close(conn)
            }
        }
    }

    func stop() {
        Darwin.close(listenFD)
        unlink(socketPath)
    }

    private func serve(_ fd: Int32) {
        guard let header = Self.read(fd, 4) else { return }
        let length = header.reduce(0) { $0 << 8 | Int($1) }
        guard let message = Self.read(fd, length), let type = message.first else { return }
        var reply = Data()
        switch type {
        case 11:   // SSH_AGENTC_REQUEST_IDENTITIES
            reply.append(12)
            reply.append(Self.uint32(identities.count))
            for identity in identities {
                reply.append(Self.string(identity.blob))
                reply.append(Self.string(Data(identity.comment.utf8)))
            }
        case 13:   // SSH_AGENTC_SIGN_REQUEST: string key, string data, uint32 flags
            var rest = message.dropFirst()
            let key = Self.takeString(&rest), data = Self.takeString(&rest)
            lock.withLock { _signRequests.append((key, data)) }
            if let signature {
                reply.append(14)
                reply.append(Self.string(signature))
            } else {
                reply.append(5)
            }
        default:
            reply.append(5)
        }
        let framed = Self.uint32(reply.count) + reply
        _ = framed.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, framed.count, 0) }
    }

    static func uint32(_ value: Int) -> Data {
        Data([UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }
    static func string(_ data: Data) -> Data { uint32(data.count) + data }
    static func keyBlob(_ algorithm: String, body: [UInt8] = [1, 2, 3]) -> Data {
        string(Data(algorithm.utf8)) + string(Data(body))
    }
    private static func takeString(_ data: inout Data.SubSequence) -> Data {
        let length = data.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        data = data.dropFirst(4)
        let value = Data(data.prefix(length))
        data = data.dropFirst(length)
        return value
    }
    private static func read(_ fd: Int32, _ count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = Darwin.recv(fd, &buffer[got], count - got, 0)
            guard n > 0 else { return nil }
            got += n
        }
        return Data(buffer)
    }
}

final class SSHAgentTests: XCTestCase {

    private var fake: FakeSSHAgent!

    override func setUpWithError() throws { fake = try FakeSSHAgent() }
    override func tearDownWithError() throws { fake.stop() }

    private var agent: SSHAgent { SSHAgent(socketPath: fake.socketPath) }

    func test_identities_parsesKeysAndComments() throws {
        fake.identities = [
            (FakeSSHAgent.keyBlob("ssh-ed25519"), "laptop"),
            (FakeSSHAgent.keyBlob("ecdsa-sha2-nistp256"), "work key"),
        ]

        let identities = try agent.identities()

        XCTAssertEqual(identities.map(\.algorithm), ["ssh-ed25519", "ecdsa-sha2-nistp256"])
        XCTAssertEqual(identities.map(\.comment), ["laptop", "work key"])
        XCTAssertEqual(identities.first?.keyBlob, FakeSSHAgent.keyBlob("ssh-ed25519"))
    }

    func test_sign_sendsTheKeyAndData_andReturnsTheAgentsSignatureBlob() throws {
        let blob = FakeSSHAgent.keyBlob("ssh-ed25519")
        fake.signature = FakeSSHAgent.keyBlob("ssh-ed25519", body: [9, 9, 9, 9])

        let signature = try agent.sign(Data("payload".utf8), with: blob)

        XCTAssertEqual(signature, FakeSSHAgent.keyBlob("ssh-ed25519", body: [9, 9, 9, 9]))
        XCTAssertEqual(fake.signRequests.first?.key, blob)
        XCTAssertEqual(fake.signRequests.first?.data, Data("payload".utf8))
    }

    func test_sign_agentRefuses_throws() {
        fake.signature = nil
        XCTAssertThrowsError(try agent.sign(Data("payload".utf8), with: FakeSSHAgent.keyBlob("ssh-ed25519")))
    }

    /// The agent being enabled must never be what stops a connection: a
    /// missing or stale socket just means there are no agent keys to offer.
    func test_missingSocket_yieldsNoKeysInsteadOfThrowing() {
        let gone = SSHAgent(socketPath: "/tmp/tp-agent-does-not-exist.sock")
        XCTAssertTrue(gone.usableIdentities(limit: 5).isEmpty)
        XCTAssertTrue(gone.privateKeys(limit: 5).isEmpty)
    }

    /// Servers allow only a few tries per connection (OpenSSH: 6). Offering
    /// every key in a well-stocked agent would lock the user out before the
    /// right key, or the password, got its turn.
    func test_usableIdentities_areCapped_putRSALast_andDropUnknownKeyTypes() {
        fake.identities = [
            (FakeSSHAgent.keyBlob("ssh-rsa", body: [1]), "old rsa"),
            (FakeSSHAgent.keyBlob("sk-ssh-ed25519@openssh.com", body: [2]), "security key"),
            (FakeSSHAgent.keyBlob("ssh-ed25519", body: [3]), "a"),
            (FakeSSHAgent.keyBlob("ecdsa-sha2-nistp384", body: [4]), "b"),
            (FakeSSHAgent.keyBlob("ssh-ed25519", body: [5]), "c"),
            (FakeSSHAgent.keyBlob("ecdsa-sha2-nistp256", body: [6]), "d"),
            (FakeSSHAgent.keyBlob("ecdsa-sha2-nistp521", body: [7]), "e"),
            (FakeSSHAgent.keyBlob("ssh-ed25519", body: [8]), "f"),
        ]

        XCTAssertEqual(agent.usableIdentities(limit: 5).map(\.comment), ["a", "b", "c", "d", "e"])
        XCTAssertEqual(agent.usableIdentities(limit: 10).map(\.comment), ["a", "b", "c", "d", "e", "f", "old rsa"])
        XCTAssertEqual(agent.privateKeys(limit: 5).count, 5)
    }

    func test_fromEnvironment_isNilWithoutASocket() {
        XCTAssertNil(SSHAgent.from(environment: [:]))
        XCTAssertNil(SSHAgent.from(environment: ["SSH_AUTH_SOCK": ""]))
        XCTAssertEqual(SSHAgent.from(environment: ["SSH_AUTH_SOCK": "/tmp/x"])?.socketPath, "/tmp/x")
    }

    // MARK: - Connection

    func test_connection_savedBeforeTheAgentOptionExisted_decodesWithItOff() throws {
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Connection(host: "example.com"))) as? [String: Any]
        )
        legacy.removeValue(forKey: "useSSHAgent")
        let data = try JSONSerialization.data(withJSONObject: legacy)

        let decoded = try JSONDecoder().decode(Connection.self, from: data)

        XCTAssertFalse(decoded.useSSHAgent)
        XCTAssertEqual(decoded.host, "example.com")
    }

    func test_connection_roundTripsTheAgentOption() throws {
        var connection = Connection(host: "example.com")
        connection.useSSHAgent = true
        let decoded = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(connection))
        XCTAssertTrue(decoded.useSSHAgent)
    }
}
