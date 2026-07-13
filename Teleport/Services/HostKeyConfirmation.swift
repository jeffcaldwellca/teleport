import Foundation
import Observation

/// Information shown to the user when they're being asked to trust a brand-new
/// SSH host key (TOFU first-use prompt).
struct HostKeyConfirmationRequest: Identifiable, Sendable {
    let id = UUID()
    let host: String
    let port: Int
    let fingerprint: String
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

    private init() {}

    /// Show the prompt and wait for the user's decision.
    func confirm(host: String, port: Int, fingerprint: String) async -> Bool {
        // If another prompt is already in flight, reject the new one rather
        // than overwriting state — should never happen in practice, but keep
        // the contract simple.
        guard pending == nil else { return false }

        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.pending = HostKeyConfirmationRequest(
                host: host, port: port, fingerprint: fingerprint
            )
        }
    }

    /// Called from the sheet when the user trusts the key.
    func accept() {
        let cont = continuation
        continuation = nil
        pending = nil
        cont?.resume(returning: true)
    }

    /// Called from the sheet when the user rejects.
    func reject() {
        let cont = continuation
        continuation = nil
        pending = nil
        cont?.resume(returning: false)
    }
}
