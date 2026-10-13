import Foundation
import Observation
import TeleportKit

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
/// `SFTPClient` awaits `passphrase(for:keyPath:rejected:)`; the sheet answers
/// by calling `submit` or `cancel`.
@Observable
@MainActor
final class PassphrasePrompt {

    static let shared = PassphrasePrompt(store: KeychainPassphraseStore()) { keyPath, passphrase in
        guard let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8) else { return nil }
        return SSHPrivateKeyFile.canUnlock(keyText, passphrase: passphrase)
    }

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let keyPath: String
        /// The previous passphrase didn't unlock the key. Flips to true on
        /// the same request when a typed passphrase is turned down, so the
        /// sheet stays up rather than being replaced.
        var isRetry: Bool
    }

    /// Currently shown request; drives the sheet binding.
    private(set) var pending: Request?

    private let store: PassphraseStoring
    /// Does this passphrase open the key at this path? nil when it can't be
    /// checked (the file can't be read here), in which case it's accepted.
    private let verify: (_ keyPath: String, _ passphrase: String) -> Bool?
    private var pendingConnection: UUID?
    private var continuation: CheckedContinuation<String?, Never>?

    /// Passphrases entered this session, whether or not they were saved, so
    /// the connections that open right after one another (the browser
    /// session, then each transfer worker) ask once between them.
    private var session: [UUID: String] = [:]

    /// One sheet at a time. Whoever is waiting when a sheet is answered is
    /// either handed that answer (same connection — including "no", so
    /// cancelling doesn't bring up a sheet per queued connection) or told the
    /// way is clear (a different connection).
    private enum Turn {
        case answered(String?)
        case proceed
    }
    private var busy = false
    private var waiters: [(connection: UUID, continuation: CheckedContinuation<Turn, Never>)] = []

    init(store: PassphraseStoring, verify: @escaping (String, String) -> Bool?) {
        self.store = store
        self.verify = verify
    }

    /// - Parameter rejected: the passphrase this caller was given before and
    ///   found not to work; nil on a first ask.
    func passphrase(for connectionID: UUID, keyPath: String, rejected: String?) async -> String? {
        if let rejected {
            // Forget exactly what failed. If someone has entered a different
            // one since, that newer passphrase stands — and is the answer.
            if session[connectionID] == rejected { session[connectionID] = nil }
            if store.loadPassphrase(for: connectionID) == rejected { store.deletePassphrase(for: connectionID) }
        }
        if let known = session[connectionID] ?? store.loadPassphrase(for: connectionID) {
            session[connectionID] = known
            return known
        }

        while busy {
            let turn = await withCheckedContinuation { waiters.append((connectionID, $0)) }
            if case .answered(let answer) = turn { return answer }
        }
        busy = true
        let answer: String? = await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pendingConnection = connectionID
            self.pending = Request(keyPath: keyPath, isRetry: rejected != nil)
        }
        busy = false

        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting {
            waiter.continuation.resume(returning: waiter.connection == connectionID ? .answered(answer) : .proceed)
        }
        return answer
    }

    /// Called from the sheet with what the user typed. A passphrase that
    /// doesn't open the key is turned down here — the sheet stays up, and
    /// nothing is remembered.
    func submit(_ passphrase: String, remember: Bool) {
        guard let connectionID = pendingConnection, let request = pending else { return }
        if verify(request.keyPath, passphrase) == false {
            pending?.isRetry = true
            return
        }
        session[connectionID] = passphrase
        if remember { store.savePassphrase(passphrase, for: connectionID) }
        finish(with: passphrase)
    }

    /// Called from the sheet when it is dismissed without an answer.
    func cancel() {
        finish(with: nil)
    }

    /// Drop everything remembered for a connection (it was deleted, or never saved).
    func forget(_ connectionID: UUID) {
        session[connectionID] = nil
        store.deletePassphrase(for: connectionID)
    }

    private func finish(with answer: String?) {
        let waiting = continuation
        continuation = nil
        pendingConnection = nil
        pending = nil
        waiting?.resume(returning: answer)
    }
}
