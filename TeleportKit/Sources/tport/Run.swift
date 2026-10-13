import ArgumentParser
import Foundation
import TeleportCLICore

/// Runs `body`, and on failure prints "error: ..." to stderr and throws the
/// ArgumentParser `ExitCode` matching `TportExitCode.map(error)` — the one
/// mechanism ArgumentParser's `main()` honors for a non-1 process exit code.
func runTport(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch {
        FileHandle.standardError.write(Data("error: \(describe(error))\n".utf8))
        if let note = FailureNotes.shared.sshConfigResolution {
            FileHandle.standardError.write(Data("note: \(note)\n".utf8))
        }
        throw ExitCode(TportExitCode.map(error).rawValue)
    }
}

/// Context worth printing alongside an error, recorded as the command runs.
final class FailureNotes: @unchecked Sendable {
    static let shared = FailureNotes()
    private let lock = NSLock()
    private var _sshConfigResolution: String?

    /// Set when the ssh config changed where an sftp:// URL actually connects.
    var sshConfigResolution: String? {
        get { lock.withLock { _sshConfigResolution } }
        set { lock.withLock { _sshConfigResolution = newValue } }
    }
}

private func describe(_ error: Error) -> String {
    // `error as? CustomStringConvertible` would always "succeed" here via
    // NSError bridging (even for types that don't declare the conformance),
    // producing NSError's noisy default description instead of the message
    // the type actually authored — check LocalizedError first instead, which
    // every error type thrown in this codebase conforms to.
    if let localized = error as? LocalizedError, let d = localized.errorDescription { return d }
    return String(describing: error)
}
