import XCTest
import NIOCore
import NIOEmbedded
@testable import NIOSSH

/// The server half of the vendored keyboard-interactive patch, driven
/// directly: a response that no challenge asked for is a protocol error,
/// not something to hand to the delegate.
final class KeyboardInteractiveServerStateTests: XCTestCase {

    private final class Delegate: NIOSSHServerUserAuthenticationDelegate, NIOSSHServerKeyboardInteractiveDelegate {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password, .keyboardInteractive]
        var keyboardInteractiveDelegate: NIOSSHServerKeyboardInteractiveDelegate? { self }
        private(set) var responsesSeen = 0

        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            // Leave the password request pending, as a slow PAM would.
        }
        func keyboardInteractiveBegan(username: String, submethods: String,
                                      promise: EventLoopPromise<NIOSSHKeyboardInteractiveServerStep>) {
            promise.succeed(.challenge(.init(name: "", instruction: "", prompts: [.init(text: "Code: ", echo: false)])))
        }
        func keyboardInteractiveResponded(responses: [String],
                                          promise: EventLoopPromise<NIOSSHKeyboardInteractiveServerStep>) {
            responsesSeen += 1
            promise.succeed(.success)
        }
    }

    func test_infoResponseWithoutAChallenge_isAProtocolViolation_notADelegateCall() throws {
        let loop = EmbeddedEventLoop()
        let delegate = Delegate()
        let configuration = SSHServerConfiguration(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: delegate)
        var machine = UserAuthenticationStateMachine(role: .server(configuration), loop: loop, sessionID: ByteBuffer(bytes: [1, 2, 3]))

        _ = try machine.receiveServiceRequest(.init(service: "ssh-userauth"))
        machine.sendServiceAccept(.init(service: "ssh-userauth"))
        // A password request is outstanding — not a keyboard-interactive one.
        _ = try machine.receiveUserAuthRequest(.init(username: "alice", service: "ssh-connection", method: .password("x")))

        XCTAssertThrowsError(try machine.receiveUserAuthInfoResponse(.init(responses: ["424242"])))
        XCTAssertEqual(delegate.responsesSeen, 0)
    }
}
