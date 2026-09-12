import Foundation

/// Helpers for validating and sanitizing paths and filenames at the network/UI boundary.
///
/// FTP commands are CRLF-terminated, so a `\r` or `\n` smuggled into a path
/// turns one command into many — classic command injection. SFTP is binary, but
/// path traversal in server-supplied listings (`../`, embedded `/`, RTL override)
/// is just as dangerous when the names are turned into local file destinations.
public enum RemotePath {

    /// Validate a string about to be sent inside an FTP command. Throws if the
    /// string contains `\r`, `\n`, or NUL — characters that would break the
    /// command framing or POSIX path semantics on the server side.
    public static func validateCommand(_ command: String) throws {
        for scalar in command.unicodeScalars {
            switch scalar {
            case "\r", "\n", "\0":
                throw RemotePathError.invalidCharacters
            default:
                continue
            }
        }
    }

    /// Sanitize a server-supplied filename before using it as a local file
    /// destination or echoing it back as part of a server command. Returns
    /// `nil` if the name is unsafe and should be dropped from the listing.
    public static func sanitizedFilename(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        // Path separators in a filename → traversal vector.
        if name.contains("/") || name.contains("\\") { return nil }

        for scalar in name.unicodeScalars {
            // C0/DEL controls (incl. \r, \n, \0).
            if scalar.value < 0x20 || scalar.value == 0x7F { return nil }
            // Bidirectional override / isolate characters (RTL homograph attacks).
            if (0x202A...0x202E).contains(scalar.value) { return nil }
            if (0x2066...0x2069).contains(scalar.value) { return nil }
        }
        return name
    }

    /// Append `name` to a remote directory path with exactly one separator,
    /// whether or not `parent` already ends in one (`/` root included).
    public static func join(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? "\(parent)\(name)" : "\(parent)/\(name)"
    }

    /// Confirm a destination URL stays inside `base`, defeating an attacker that
    /// got `..` through earlier sanitization (defense in depth).
    public static func isContained(_ destination: URL, in base: URL) -> Bool {
        let destPath = destination.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        return destPath == basePath
            || destPath.hasPrefix(basePath.hasSuffix("/") ? basePath : basePath + "/")
    }
}

public enum RemotePathError: LocalizedError {
    case invalidCharacters
    case unsafeName(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCharacters:
            return "Path contains characters that are not allowed (control characters or NUL)."
        case .unsafeName(let name):
            return "'\(name)' isn't a valid name — it can't contain /, \\, or control characters."
        }
    }
}
