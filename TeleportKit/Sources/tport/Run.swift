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
        throw ExitCode(TportExitCode.map(error).rawValue)
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
