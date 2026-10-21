import Foundation

/// What an SSH server asks during a keyboard-interactive login (RFC 4256):
/// a password prompt on servers that take passwords only that way, a
/// verification code as the second step of a two-factor setup, or anything
/// else its PAM stack wants to know.
public struct KeyboardInteractiveChallenge: Hashable, Sendable {
    public struct Prompt: Hashable, Sendable {
        public let text: String
        /// Whether the answer may be shown as it's typed; false for secrets.
        public let echo: Bool

        public init(text: String, echo: Bool) {
            self.text = KeyboardInteractiveChallenge.displayable(text, keepingLineBreaks: false)
            self.echo = echo
        }
    }

    /// A title for the exchange; often empty.
    public let name: String
    /// Text to show above the prompts; often empty.
    public let instruction: String
    public let prompts: [Prompt]

    /// Every string here comes from the server and ends up on a terminal
    /// or in a sheet, so control characters (terminal escapes among them)
    /// and text-direction overrides are dropped at construction.
    public init(name: String, instruction: String, prompts: [Prompt]) {
        self.name = Self.displayable(name, keepingLineBreaks: false)
        self.instruction = Self.displayable(instruction, keepingLineBreaks: true)
        self.prompts = prompts
    }

    /// `text` without C0/C1 control characters, DEL, or Unicode
    /// bidirectional overrides and isolates (U+202A–U+202E, U+2066–U+2069).
    static func displayable(_ text: String, keepingLineBreaks: Bool) -> String {
        String(text.unicodeScalars.filter { scalar in
            if scalar == "\n" { return keepingLineBreaks }
            if scalar.properties.generalCategory == .control { return false }
            return !(0x202A...0x202E).contains(scalar.value) && !(0x2066...0x2069).contains(scalar.value)
        }.map(Character.init))
    }

    /// The prompts' text, for messages: "Verification code: ".
    public var promptSummary: String {
        prompts.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
    }
}

/// Answers a challenge with one response per prompt, in order, or nil to
/// give up on the login.
public typealias InteractivePromptProvider = @Sendable (KeyboardInteractiveChallenge) async -> [String]?
