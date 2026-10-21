import XCTest
import NIOCore
@testable import NIOSSH

/// Wire format of the keyboard-interactive messages added to the vendored
/// swift-nio-ssh (RFC 4256), and the parse of message number 60, which is
/// SSH_MSG_USERAUTH_PK_OK or SSH_MSG_USERAUTH_INFO_REQUEST depending on the
/// method of the outstanding request.
final class KeyboardInteractiveMessageTests: XCTestCase {

    private func roundTrip(_ message: SSHMessage, expecting hint: SSHMessage.MethodSpecificMessage) throws -> SSHMessage? {
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        buffer.writeSSHMessage(message)
        let parsed = try buffer.readSSHMessage(methodSpecific: hint)
        XCTAssertEqual(buffer.readableBytes, 0, "trailing bytes after parse")
        return parsed
    }

    func test_infoRequest_roundTrips_whenKeyboardInteractiveIsOutstanding() throws {
        let request = SSHMessage.UserAuthInfoRequestMessage(
            name: "Two-step login", instruction: "Enter the code from your app", languageTag: "",
            prompts: [.init(prompt: "Verification code: ", echo: false), .init(prompt: "Nickname: ", echo: true)]
        )
        XCTAssertEqual(try roundTrip(.userAuthInfoRequest(request), expecting: .keyboardInteractive), .userAuthInfoRequest(request))
    }

    func test_number60_isPublicKeyOK_whenPublicKeyIsOutstanding() throws {
        let key = NIOSSHPrivateKey(ed25519Key: .init()).publicKey
        XCTAssertEqual(try roundTrip(.userAuthPKOK(.init(key: key)), expecting: .publicKey), .userAuthPKOK(.init(key: key)))
    }

    func test_infoResponse_roundTrips() throws {
        let response = SSHMessage.UserAuthInfoResponseMessage(responses: ["123456", ""])
        XCTAssertEqual(try roundTrip(.userAuthInfoResponse(response), expecting: .publicKey), .userAuthInfoResponse(response))
    }

    func test_keyboardInteractiveRequest_roundTrips() throws {
        let request = SSHMessage.UserAuthRequestMessage(
            username: "alice", service: "ssh-connection",
            method: .keyboardInteractive(.init(languageTag: "", submethods: ""))
        )
        XCTAssertEqual(try roundTrip(.userAuthRequest(request), expecting: .publicKey), .userAuthRequest(request))
    }

    func test_serverMethodList_includesKeyboardInteractive() {
        let failure = SSHMessage.UserAuthFailureMessage(authentications: ["publickey", "keyboard-interactive"], partialSuccess: true)
        let methods = NIOSSHAvailableUserAuthenticationMethods(failure)
        XCTAssertEqual(methods, [.publicKey, .keyboardInteractive])
        XCTAssertEqual(Set(methods.strings), ["publickey", "keyboard-interactive"])
    }
}
