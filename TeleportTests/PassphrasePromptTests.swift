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
    /// What the "key file" accepts; nil means the passphrase can't be checked.
    private var correctPassphrase: String?

    override func setUp() async throws {
        store = MemoryPassphraseStore()
        correctPassphrase = nil
        prompt = PassphrasePrompt(store: store) { [unowned self] _, passphrase in
            correctPassphrase.map { $0 == passphrase }
        }
    }

    private func ask(_ id: UUID? = nil, rejected: String? = nil) -> Task<String?, Never> {
        Task { await prompt.passphrase(for: id ?? connection, keyPath: "/keys/id_ed25519", rejected: rejected) }
    }

    private func waitForPrompt(where matches: @MainActor (PassphrasePrompt.Request) -> Bool = { _ in true }) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(prompt.pending.map(matches) ?? false) {
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

    func test_rejectedPassphrase_isForgottenEverywhere_andAskedForAgain() async throws {
        store.saved[connection] = "stale"

        let asking = ask(rejected: "stale")
        try await waitForPrompt()
        XCTAssertEqual(prompt.pending?.isRetry, true)
        XCTAssertNil(store.saved[connection], "A passphrase that didn't work must not stay in the Keychain")

        prompt.submit("fresh", remember: true)
        let result = await asking.value
        XCTAssertEqual(result, "fresh")
    }

    /// A slow connection reporting that the *old* passphrase failed must not
    /// throw away the correct one someone has entered since.
    func test_rejectionOfAnOlderPassphrase_keepsTheNewerOne_andReturnsIt() async throws {
        let first = ask()
        try await waitForPrompt()
        prompt.submit("good", remember: true)
        _ = await first.value

        let late = await ask(rejected: "old-wrong").value

        XCTAssertEqual(late, "good")
        XCTAssertEqual(store.saved[connection], "good")
        XCTAssertNil(prompt.pending)
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

    /// …but only for them. Having said no once must not silently answer a
    /// later, separate attempt that happens to queue behind another sheet.
    func test_anEarlierCancel_doesNotAnswerALaterAskThatQueuesBehindAnotherConnection() async throws {
        let declined = ask()
        try await waitForPrompt()
        prompt.cancel()
        _ = await declined.value

        let other = UUID()
        let otherAsk = ask(other)
        try await waitForPrompt()
        let otherRequest = try XCTUnwrap(prompt.pending)
        let again = ask()                       // queues behind `other`'s sheet
        try await Task.sleep(for: .milliseconds(50))

        prompt.submit("other's passphrase", remember: false)
        _ = await otherAsk.value

        try await waitForPrompt { $0.id != otherRequest.id }   // a sheet of its own
        prompt.submit("typed this time", remember: false)
        let result = await again.value
        XCTAssertEqual(result, "typed this time")
    }

    /// The sheet checks the passphrase against the key before accepting it,
    /// so a typo is caught on the spot and never reaches the Keychain.
    func test_wrongPassphrase_isCaughtInTheSheet_andNeverStored() async throws {
        correctPassphrase = "good"
        let asking = ask()
        try await waitForPrompt()
        let shown = try XCTUnwrap(prompt.pending)

        prompt.submit("typo", remember: true)

        XCTAssertEqual(prompt.pending?.id, shown.id, "The same sheet stays up")
        XCTAssertEqual(prompt.pending?.isRetry, true)
        XCTAssertNil(store.saved[connection])

        prompt.submit("good", remember: true)
        let result = await asking.value
        XCTAssertEqual(result, "good")
        XCTAssertEqual(store.saved[connection], "good")
    }

    /// Testing a connection that is then never saved must not leave its
    /// passphrase behind.
    func test_forget_removesTheStoredAndSessionPassphrase() async throws {
        let asking = ask()
        try await waitForPrompt()
        prompt.submit("typed", remember: true)
        _ = await asking.value

        prompt.forget(connection)

        XCTAssertNil(store.saved[connection])
        let again = ask()
        try await waitForPrompt()      // has to ask: nothing remembered
        prompt.cancel()
        _ = await again.value
    }
}
