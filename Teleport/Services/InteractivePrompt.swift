import Foundation
import Observation
import TeleportKit

/// MainActor bridge between the SFTP connect flow and the keyboard-interactive
/// sheet: `SFTPClient` awaits `answer(for:challenge:)`; the sheet answers by
/// calling `submit` or `cancel`. One sheet at a time; the connections that
/// open right after one another (the browser session, then each transfer
/// worker) wait their turn rather than stacking sheets.
@Observable
@MainActor
final class InteractivePrompt {

    static let shared = InteractivePrompt()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        /// The connection's name, for the sheet's title.
        let connectionName: String
        let challenge: KeyboardInteractiveChallenge
    }

    /// Currently shown request; drives the sheet binding.
    private(set) var pending: Request?

    private var continuation: CheckedContinuation<[String]?, Never>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Shows the server's prompts and returns the answers, or nil when the
    /// sheet is dismissed.
    func answer(for connectionName: String, challenge: KeyboardInteractiveChallenge) async -> [String]? {
        while busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        let answers: [String]? = await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = Request(connectionName: connectionName, challenge: challenge)
        }
        busy = false
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
        return answers
    }

    /// Called from the sheet with one answer per prompt.
    func submit(_ answers: [String]) {
        finish(with: answers)
    }

    /// Called from the sheet when it is dismissed without answering.
    func cancel() {
        finish(with: nil)
    }

    private func finish(with answers: [String]?) {
        let waiting = continuation
        continuation = nil
        pending = nil
        waiting?.resume(returning: answers)
    }
}
