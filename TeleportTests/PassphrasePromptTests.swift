import XCTest
@testable import Teleport

/// In-memory stand-in for the Keychain, so tests never touch the real one.
@MainActor
private final class MemoryPassphraseStore: PassphraseStoring {
    var saved: [UUID: String] = [:]
    func loadPassphrase(for connectionID: UUID) -> String? { saved[connectionID] }
    func savePassphrase(_ passphrase: String, for connectionID: UUID) { saved[connectionID] = passphrase }
    func deletePassphrase(for connectionID: UUID) { saved[connectionID] = nil }
}

@MainActor
final class PassphrasePromptTests: XCTestCase {

    private let connection = UUID()
    private var store: MemoryPassphraseStore!
    private var prompt: PassphrasePrompt!

    override func setUp() async throws {
        store = MemoryPassphraseStore()
        prompt = PassphrasePrompt(store: store)
    }

    private func ask(retry: Bool = false) -> Task<String?, Never> {
        Task { await prompt.passphrase(for: connection, keyPath: "/keys/id_ed25519", retry: retry) }
    }

    private func waitForPrompt() async throws {
        let deadline = Date().addingTimeInterval(5)
        while prompt.pending == nil {
            if Date() > deadline { XCTFail("No prompt appeared"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func test_storedPassphrase_isReturnedWithoutPrompting() async {
        store.saved[connection] = "from keychain"

        let result = await ask().value

        XCTAssertEqual(result, "from keychain")
        XCTAssertNil(prompt.pending)
    }

    func test_nothingStored_prompts_andSubmitWithRemember_storesIt() async throws {
        let asking = ask()
        try await waitForPrompt()
        XCTAssertEqual(prompt.pending?.keyPath, "/keys/id_ed25519")
        XCTAssertEqual(prompt.pending?.isRetry, false)

        prompt.submit("typed", remember: true)

        let result = await asking.value
        XCTAssertEqual(result, "typed")
        XCTAssertEqual(store.saved[connection], "typed")
        XCTAssertNil(prompt.pending)
    }

    func test_submitWithoutRemember_isNotStored_butIsReusedForTheRestOfTheSession() async throws {
        let asking = ask()
        try await waitForPrompt()
        prompt.submit("typed", remember: false)
        _ = await asking.value

        XCTAssertNil(store.saved[connection])
        // e.g. the transfer queue's workers connecting moments later.
        let again = await ask().value
        XCTAssertEqual(again, "typed")
    }

    func test_retry_discardsTheStoredPassphrase_andPromptsAgain() async throws {
        store.saved[connection] = "stale"

        let asking = ask(retry: true)
        try await waitForPrompt()
        XCTAssertEqual(prompt.pending?.isRetry, true)
        XCTAssertNil(store.saved[connection], "A passphrase that didn't work must not stay in the Keychain")

        prompt.submit("fresh", remember: true)
        let result = await asking.value
        XCTAssertEqual(result, "fresh")
    }

    func test_cancel_returnsNil() async throws {
        let asking = ask()
        try await waitForPrompt()

        prompt.cancel()

        let result = await asking.value
        XCTAssertNil(result)
    }

    /// Several connections opening at once (the browser session plus queue
    /// workers) must produce one sheet, not a stack of them.
    func test_concurrentAsks_showOnePrompt_andAllGetTheAnswer() async throws {
        let first = ask(), second = ask(), third = ask()
        try await waitForPrompt()

        prompt.submit("typed", remember: false)

        let results = await [first.value, second.value, third.value]
        XCTAssertEqual(results, ["typed", "typed", "typed"])
        XCTAssertNil(prompt.pending)
    }

    /// Cancelling means "no" for everyone who was waiting on that answer —
    /// not a fresh sheet for each queued connection.
    func test_cancel_answersEveryoneWaiting_withoutPromptingAgain() async throws {
        let first = ask(), second = ask(), third = ask()
        try await waitForPrompt()

        prompt.cancel()

        let results = await [first.value, second.value, third.value]
        XCTAssertEqual(results, [nil, nil, nil])
        XCTAssertNil(prompt.pending)
    }
}
