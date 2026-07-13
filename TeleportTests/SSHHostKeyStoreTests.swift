import XCTest
import TeleportKit

final class SSHHostKeyStoreTests: XCTestCase {

    private func makeStore() -> (SSHHostKeyStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(component: "known-hosts-test-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (SSHHostKeyStore(storeURL: url), url)
    }

    func test_record_thenFingerprint_roundTrips() async throws {
        let (store, _) = makeStore()
        let before = await store.fingerprint(for: "example.com", port: 22)
        XCTAssertNil(before)
        try await store.record(host: "example.com", port: 22, fingerprint: "SHA256:abc")
        let fp = await store.fingerprint(for: "example.com", port: 22)
        XCTAssertEqual(fp, "SHA256:abc")
    }

    func test_record_persistsAcrossInstances() async throws {
        let (store, url) = makeStore()
        try await store.record(host: "example.com", port: 22, fingerprint: "SHA256:abc")

        let reopened = SSHHostKeyStore(storeURL: url)
        let fp = await reopened.fingerprint(for: "example.com", port: 22)
        XCTAssertEqual(fp, "SHA256:abc")
    }

    func test_forget_removesOnlyThatHost() async throws {
        let (store, _) = makeStore()
        try await store.record(host: "a.example.com", port: 22, fingerprint: "SHA256:a")
        try await store.record(host: "b.example.com", port: 22, fingerprint: "SHA256:b")
        try await store.forget(host: "a.example.com", port: 22)
        let a = await store.fingerprint(for: "a.example.com", port: 22)
        let b = await store.fingerprint(for: "b.example.com", port: 22)
        XCTAssertNil(a)
        XCTAssertEqual(b, "SHA256:b")
    }

    func test_forgetAll_clearsEverything() async throws {
        let (store, _) = makeStore()
        try await store.record(host: "a.example.com", port: 22, fingerprint: "SHA256:a")
        try await store.record(host: "b.example.com", port: 22, fingerprint: "SHA256:b")
        try await store.forgetAll()
        let hosts = await store.trustedHosts()
        XCTAssertTrue(hosts.isEmpty)
    }

    func test_nilStoreURL_neverPersistsAcrossInstances() async throws {
        let store = SSHHostKeyStore(storeURL: nil)
        try await store.record(host: "example.com", port: 22, fingerprint: "SHA256:abc")
        // Still readable within the same instance (in-memory)...
        let fp = await store.fingerprint(for: "example.com", port: 22)
        XCTAssertEqual(fp, "SHA256:abc")
        // ...but a fresh instance with the same nil URL starts empty.
        let fresh = SSHHostKeyStore(storeURL: nil)
        let freshFp = await fresh.fingerprint(for: "example.com", port: 22)
        XCTAssertNil(freshFp)
    }

    func test_trustedHosts_sortedByHostThenPort() async throws {
        let (store, _) = makeStore()
        try await store.record(host: "b.example.com", port: 22, fingerprint: "SHA256:b")
        try await store.record(host: "a.example.com", port: 2222, fingerprint: "SHA256:a2")
        try await store.record(host: "a.example.com", port: 22, fingerprint: "SHA256:a1")
        let hosts = await store.trustedHosts()
        XCTAssertEqual(hosts.map { "\($0.host):\($0.port)" }, [
            "a.example.com:22", "a.example.com:2222", "b.example.com:22",
        ])
    }
}
