import XCTest
@testable import Teleport

@MainActor
final class HostKeyConfirmationTests: XCTestCase {

    private func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// With several sessions connecting at once, two never-seen hosts can ask
    /// at the same moment. The second used to be refused without a word.
    func test_twoHostsAskingAtOnce_areShownOneAfterTheOther() async throws {
        let confirmation = HostKeyConfirmation()
        let first = Task { await confirmation.confirm(host: "one.example.com", port: 22, fingerprint: "SHA256:aa") }
        try await waitUntil("first prompt") { confirmation.pending?.host == "one.example.com" }
        let second = Task { await confirmation.confirm(host: "two.example.com", port: 22, fingerprint: "SHA256:bb") }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(confirmation.pending?.host, "one.example.com", "One sheet at a time")

        confirmation.accept()
        try await waitUntil("second prompt") { confirmation.pending?.host == "two.example.com" }
        confirmation.reject()

        let answers = await [first.value, second.value]
        XCTAssertEqual(answers, [true, false])
        XCTAssertNil(confirmation.pending)
    }
}
