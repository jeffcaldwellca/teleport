import Foundation

/// Installs the `tport` CLI (bundled inside the app as a resource) onto the
/// user's PATH, the same way editors like VS Code offer to install their
/// `code` command: symlink into /usr/local/bin via an admin-privileged
/// AppleScript `do shell script`, which surfaces the standard macOS
/// password prompt.
enum CommandLineToolInstaller {

    static let installPath = "/usr/local/bin/tport"

    /// The `tport` binary bundled at Contents/Resources/tport, or nil if
    /// this build didn't embed one.
    static func bundledBinaryPath() -> String? {
        Bundle.main.url(forResource: "tport", withExtension: nil)?.path
    }

    /// True if /usr/local/bin/tport already resolves to the bundled binary
    /// path exactly (not just "some file exists there").
    static func isInstalled() -> Bool {
        guard let bundled = bundledBinaryPath() else { return false }
        guard let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: installPath) else {
            return false
        }
        return resolved == bundled
    }

    /// Prompts for administrator privileges and symlinks the bundled binary
    /// into /usr/local/bin. Throws `InstallError.cancelled` if the user
    /// declines the password prompt.
    static func install() throws {
        guard let bundled = bundledBinaryPath() else {
            throw InstallError.binaryMissing
        }
        let escapedTarget = shellEscape(bundled)
        let escapedLink = shellEscape(installPath)
        let command = "mkdir -p /usr/local/bin && ln -sf \(escapedTarget) \(escapedLink)"
        let script = "do shell script \"\(command)\" with administrator privileges"

        guard let appleScript = NSAppleScript(source: script) else {
            throw InstallError.scriptFailed("Could not construct the installer script.")
        }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -128 {   // user cancelled the authorization prompt
                throw InstallError.cancelled
            }
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown error"
            throw InstallError.scriptFailed(message)
        }
    }

    /// Single-quotes a path for safe embedding in a shell command, escaping
    /// any literal single quotes it contains.
    private static func shellEscape(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    enum InstallError: LocalizedError {
        case binaryMissing
        case cancelled
        case scriptFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "The tport binary wasn't found inside the app bundle."
            case .cancelled:
                return "Installation was cancelled."
            case .scriptFailed(let message):
                return "Could not install tport: \(message)"
            }
        }
    }
}
