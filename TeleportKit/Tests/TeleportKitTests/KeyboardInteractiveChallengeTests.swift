import XCTest
import TeleportKit

/// Everything in a challenge comes from the server, and is shown on a
/// terminal or in a sheet: control characters and text-direction overrides
/// must not make it through.
final class KeyboardInteractiveChallengeTests: XCTestCase {

    func test_controlCharactersAreDroppedFromPrompts_andLineBreaksKeptInInstructions() {
        let challenge = KeyboardInteractiveChallenge(
            name: "Log\u{1b}[2Jin",
            instruction: "First line\nSecond\u{7f} line",
            prompts: [.init(text: "\u{1b}]0;owned\u{7}Password:\n ", echo: false)]
        )
        XCTAssertEqual(challenge.name, "Log[2Jin")
        XCTAssertEqual(challenge.instruction, "First line\nSecond line")
        XCTAssertEqual(challenge.prompts.map(\.text), ["]0;ownedPassword: "])
    }

    func test_textDirectionOverridesAreDropped() {
        let challenge = KeyboardInteractiveChallenge(
            name: "", instruction: "\u{202e}gnol\u{202c}",
            prompts: [.init(text: "\u{2066}Code\u{2069}: ", echo: false)]
        )
        XCTAssertEqual(challenge.instruction, "gnol")
        XCTAssertEqual(challenge.prompts.map(\.text), ["Code: "])
    }
}
