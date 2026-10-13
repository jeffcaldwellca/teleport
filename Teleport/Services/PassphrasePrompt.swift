import Foundation
import Observation

/// Where key passphrases the user chose to remember are kept.
@MainActor
protocol PassphraseStoring {
    func loadPassphrase(for connectionID: UUID) -> String?
    func savePassphrase(_ passphrase: String, for connectionID: UUID)
    func deletePassphrase(for connectionID: UUID)
}

/// The login Keychain, one item per connection alongside its password.
@MainActor
struct KeychainPassphraseStore: PassphraseStoring {
    func loadPassphrase(for connectionID: UUID) -> String? {
        try? KeychainService.load(account: KeychainService.passphraseAccount(for: connectionID))
    }

    func savePassphrase(_ passphrase: String, for connectionID: UUID) {
        try? KeychainService.save(secret: passphrase, account: KeychainService.passphraseAccount(for: connectionID))
    }

    func deletePassphrase(for connectionID: UUID) {
        KeychainService.delete(account: KeychainService.passphraseAccount(for: connectionID))
    }
}

/// MainActor bridge between the SFTP connect flow and the passphrase sheet:
/// `SFTPClient` awaits `passphrase(for:keyPath:retry:)`; the sheet answers by
/// calling `submit` or `cancel`.
@Observable
@MainActor
final class PassphrasePrompt {

    static let shared = PassphrasePrompt(store: KeychainPassphraseStore())

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let keyPath: String
        /// The previous passphrase didn't unlock the key.
        let isRetry: Bool
    }

    /// Currently shown request; drives the sheet binding.
    private(set) var pending: Request?

    private let store: PassphraseStoring
    private var pendingConnection: UUID?
    private var continuation: CheckedContinuation<String?, Never>?

    /// Passphrases entered this session, whether or not they were saved, so
    /// the connections that open right after one another (the browser
    /// session, then each transfer worker) ask once between them.
    private var session: [UUID: String] = [:]

    /// Connections whose most recent prompt was cancelled (see `passphrase`).
    private var declined: Set<UUID> = []

    /// One sheet at a time; later askers wait their turn.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(store: PassphraseStoring) {
        self.store = store
    }

    func passphrase(for connectionID: UUID, keyPath: String, retry: Bool) async -> String? {
        if retry {
            // Whatever we had didn't work: forget it everywhere and ask.
            session[connectionID] = nil
            store.deletePassphrase(for: connectionID)
        } else if let known = session[connectionID] ?? store.loadPassphrase(for: connectionID) {
            session[connectionID] = known
            return known
        }

        var waited = false
        while busy {
            waited = true
            await withCheckedContinuation { waiters.append($0) }
        }
        if waited {
            // Whoever was ahead of us asked the same question: their answer
            // is ours too — including "no", so cancelling one sheet doesn't
            // bring up another for every connection that was queued behind it.
            if let known = session[connectionID] { return known }
            if declined.contains(connectionID) { return nil }
        }
        declined.remove(connectionID)

        busy = true
        defer {
            busy = false
            let waiting = waiters
            waiters.removeAll()
            waiting.forEach { $0.resume() }
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pendingConnection = connectionID
            self.pending = Request(keyPath: keyPath, isRetry: retry)
        }
    }

    /// Called from the sheet with what the user typed.
    func submit(_ passphrase: String, remember: Bool) {
        guard let connectionID = pendingConnection else { return }
        session[connectionID] = passphrase
        if remember { store.savePassphrase(passphrase, for: connectionID) }
        finish(with: passphrase)
    }

    /// Called from the sheet when it is dismissed without an answer.
    func cancel() {
        if let connectionID = pendingConnection { declined.insert(connectionID) }
        finish(with: nil)
    }

    private func finish(with answer: String?) {
        let waiting = continuation
        continuation = nil
        pendingConnection = nil
        pending = nil
        waiting?.resume(returning: answer)
    }
}
