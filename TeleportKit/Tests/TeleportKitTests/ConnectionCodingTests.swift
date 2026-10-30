import XCTest
import TeleportKit

final class ConnectionCodingTests: XCTestCase {

    /// A connection saved before `implicitTLS` existed, minus that key.
    private func decodeLegacy(protocol proto: String, port: Int) throws -> Connection {
        let json = """
        {"id":"\(UUID().uuidString)","name":"n","host":"h","port":\(port),"username":"u",
         "connectionProtocol":"\(proto)","initialPath":"/","sshKeyPath":"","notes":"","createdAt":0}
        """
        return try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
    }

    /// Port 990 used to be what selected implicit FTPS; saved connections keep working.
    func test_legacyFTPSOnPort990_staysImplicit() throws {
        XCTAssertTrue(try decodeLegacy(protocol: "FTPS", port: 990).implicitTLS)
        XCTAssertFalse(try decodeLegacy(protocol: "FTPS", port: 21).implicitTLS)
        XCTAssertFalse(try decodeLegacy(protocol: "FTP", port: 990).implicitTLS)
    }

    func test_implicitTLS_survivesARoundTrip_onAnyPort() throws {
        let original = Connection(host: "h", port: 2990, connectionProtocol: .ftps, implicitTLS: true)
        let decoded = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(decoded.implicitTLS)
    }
}
