import Foundation
import TeleportKit
import Observation

/// Information shown to the user when they're being asked to trust a server's
/// identity for the first time (TOFU prompt): a brand-new SSH host key, or an
/// FTPS certificate the system doesn't trust.
struct HostKeyConfirmationRequest: Identifiable, Sendable {
    let id = UUID()
    let host: String
    let port: Int
    let fingerprint: String
    /// Set for an FTPS certificate: why the system rejected it. Nil for an
    /// SSH host key.
    var certificateReason: String? = nil
}

/// MainActor singleton that bridges the SFTP-client connection flow to a
/// SwiftUI confirmation sheet. SFTPClient awaits `confirm(...)`; the sheet
/// resolves that call by calling `accept()` or `reject()`.
@Observable
@MainActor
final class HostKeyConfirmation {

    static let shared = HostKeyConfirmation()

    /// Currently-pending request, drives the SwiftUI sheet binding.
    private(set) var pending: HostKeyConfirmationRequest? = nil

    private var continuation: CheckedContinuation<Bool, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// Show the prompt and wait for the user's decision.
    func confirm(host: String, port: Int, fingerprint: String,
                 certificateReason: String? = nil) async -> Bool {
        // One sheet at a time. With several sessions connecting at once two
        // never-seen servers can ask together; the second waits its turn
        // rather than being refused unseen.
        while pending != nil {
            await withCheckedContinuation { waiters.append($0) }
        }

        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.pending = HostKeyConfirmationRequest(
                host: host, port: port, fingerprint: fingerprint,
                certificateReason: certificateReason
            )
        }
    }

    /// Called from the sheet when the user trusts the key.
    func accept() { finish(trusted: true) }

    /// Called from the sheet when the user rejects.
    func reject() { finish(trusted: false) }

    private func finish(trusted: Bool) {
        let cont = continuation
        continuation = nil
        pending = nil
        cont?.resume(returning: trusted)
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}
