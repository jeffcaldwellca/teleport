import Foundation

/// The parts of an OpenSSH client config (`~/.ssh/config`) that say where a
/// host is and who to log in as: `Host` blocks with `HostName`, `User`,
/// `Port` and `IdentityFile`.
///
/// Everything else — `Include`, `Match`, `ProxyJump`, algorithm lists and so
/// on — is skipped rather than rejected: a config that works for `ssh` must
/// never be an error here.
public struct SSHConfig: Sendable {

    public struct Host: Equatable, Sendable {
        /// The name used on the command line (`ssh <alias>`).
        public var alias: String
        /// Where to actually connect; the alias itself when no `HostName` is set.
        public var hostName: String
        public var user: String?
        public var port: Int?
        /// Absolute path of the first `IdentityFile`.
        public var identityFile: String?

        public init(alias: String, hostName: String, user: String? = nil, port: Int? = nil, identityFile: String? = nil) {
            self.alias = alias
            self.hostName = hostName
            self.user = user
            self.port = port
            self.identityFile = identityFile
        }
    }

    /// One `Host` line and the directives under it. Directives before the
    /// first `Host` belong to a block that matches everything.
    private struct Block: Sendable {
        var patterns: [String]
        var directives: [(keyword: String, value: String)] = []

        func matches(_ name: String) -> Bool {
            let negated = patterns.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
            if negated.contains(where: { SSHConfig.glob($0, matches: name) }) { return false }
            return patterns.contains { !$0.hasPrefix("!") && SSHConfig.glob($0, matches: name) }
        }
    }

    private let blocks: [Block]
    private let homeDirectory: String

    public init(text: String, homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
        var blocks = [Block(patterns: ["*"])]
        var skipping = false          // inside a Match block
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let words = Self.words(in: String(rawLine))
            guard let keyword = words.first?.lowercased() else { continue }
            switch keyword {
            case "host":
                skipping = false
                blocks.append(Block(patterns: Array(words.dropFirst())))
            case "match":
                skipping = true
            default:
                guard !skipping, words.count >= 2 else { continue }
                blocks[blocks.count - 1].directives.append((keyword, words[1]))
            }
        }
        self.blocks = blocks
    }

    /// The user's config, or an empty one if it can't be read.
    public static func load(from url: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".ssh/config")) -> SSHConfig {
        SSHConfig(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// What connecting to `name` means under this config. For each setting
    /// the first block that matches and sets it wins, as in OpenSSH — so a
    /// name no block mentions still picks up `Host *` defaults.
    public func resolve(_ name: String) -> Host {
        var host = Host(alias: name, hostName: name)
        var hostNameSet = false
        for block in blocks where block.matches(name) {
            for (keyword, value) in block.directives {
                switch keyword {
                case "hostname" where !hostNameSet:
                    host.hostName = value
                    hostNameSet = true
                case "user" where host.user == nil:
                    host.user = value
                case "port" where host.port == nil:
                    host.port = Int(value).flatMap { (1...65535).contains($0) ? $0 : nil }
                case "identityfile" where host.identityFile == nil:
                    host.identityFile = expand(value)
                default:
                    break
                }
            }
        }
        return host
    }

    /// Every host named outright (no wildcards), in file order, resolved.
    public var hosts: [Host] {
        var seen: Set<String> = []
        var result: [Host] = []
        for block in blocks.dropFirst() {
            for pattern in block.patterns where !pattern.hasPrefix("!") && !pattern.contains(where: { "*?".contains($0) }) {
                if seen.insert(pattern).inserted { result.append(resolve(pattern)) }
            }
        }
        return result
    }

    // MARK: - Parsing helpers

    /// Split a config line into words: `keyword value…`, with an optional `=`
    /// after the keyword, double-quoted values, and `#` comments.
    private static func words(in line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuotes = false
        var hasCurrent = false
        var usedEquals = false
        func flush() {
            if hasCurrent { words.append(current) }
            current = ""
            hasCurrent = false
        }
        for character in line {
            if inQuotes {
                if character == "\"" { inQuotes = false } else { current.append(character) }
            } else if character == "\"" {
                inQuotes = true
                hasCurrent = true
            } else if character == "#" && !hasCurrent {
                break
            } else if character.isWhitespace {
                flush()
            } else if character == "=", !usedEquals, words.isEmpty || (words.count == 1 && !hasCurrent) {
                // One `=` may stand between the keyword and its value, with
                // or without spaces around it. Any later `=` belongs to the
                // value (SetEnv TERM=…).
                usedEquals = true
                flush()
            } else {
                current.append(character)
                hasCurrent = true
            }
        }
        flush()
        return words
    }

    /// `~` and `%d` are the home directory. Other `%` tokens are left alone.
    private func expand(_ path: String) -> String {
        var path = path.replacingOccurrences(of: "%d", with: homeDirectory)
        if path == "~" { path = homeDirectory }
        if path.hasPrefix("~/") { path = homeDirectory + path.dropFirst(1) }
        return path
    }

    /// OpenSSH host patterns: `*` is any run of characters, `?` exactly one.
    static func glob(_ pattern: String, matches name: String) -> Bool {
        let pattern = Array(pattern.lowercased()), name = Array(name.lowercased())
        var p = 0, n = 0, star: Int? = nil, mark = 0
        while n < name.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == name[n] {
                p += 1; n += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p; mark = n; p += 1
            } else if let s = star {
                p = s + 1; mark += 1; n = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
