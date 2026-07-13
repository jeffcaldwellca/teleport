import Foundation

/// Prints a single updating progress line to stderr, only when stderr is a
/// TTY — piping/cron output stays clean with no partial-line noise.
///
/// `@unchecked Sendable`: every stored property is an immutable `let` of a
/// Sendable type, and FTPClient/SFTPClient invoke the progress closure
/// synchronously and sequentially within their own actor, never concurrently
/// — there's no actual shared mutable state for the compiler to protect.
final class ProgressPrinter: @unchecked Sendable {
    private let isTTY = isatty(STDERR_FILENO) != 0
    private let label: String

    init(label: String) { self.label = label }

    func update(bytes: Int64, total: Int64) {
        guard isTTY else { return }
        let pct = total > 0 ? Int(Double(bytes) / Double(total) * 100) : 0
        FileHandle.standardError.write(Data("\r\(label): \(pct)% (\(bytes)/\(total) bytes)".utf8))
    }

    func finish() {
        guard isTTY else { return }
        FileHandle.standardError.write(Data("\n".utf8))
    }
}
