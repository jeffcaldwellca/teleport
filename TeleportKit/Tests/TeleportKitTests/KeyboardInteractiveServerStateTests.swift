import XCTest
import NIOCore
import NIOEmbedded
@testable import NIOSSH

/// The server half of the vendored keyboard-interactive patch, driven
/// directly. A conversation is one request, its challenges and responses,
/// and a verdict; nothing outside it may be mistaken for part of it.
final class KeyboardInteractiveServerStateTests: XCTestCase {

    private final class Delegate: NIOSSHServerUserAuthenticationDelegate, NIOSSHServerKeyboardInteractiveDelegate {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password, .keyboardInteractive]
        var keyboardInteractiveDelegate: NIOSSHServerKeyboardInteractiveDelegate? { self }
        private(set) var responsesSeen: [(username: String, responses: [String])] = []
        var verdict: NIOSSHKeyboardInteractiveServerStep = .success

        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            // Leave the password request pending, as a slow PAM would.
        }
        func keyboardInteractiveBegan(username: String, submethods: String,
                                      promise: EventLoopPromise<NIOSSHKeyboardInteractiveServerStep>) {
            promise.succeed(.challenge(.init(name: "", instruction: "", prompts: [.init(text: "Code: ", echo: false)])))
        }
        func keyboardInteractiveResponded(username: String, responses: [String],
                                          promise: EventLoopPromise<NIOSSHKeyboardInteractiveServerStep>) {
            responsesSeen.append((username, responses))
            promise.succeed(verdict)
        }
    }

    private var loop = EmbeddedEventLoop()
    private var delegate = Delegate()

    private func serverAwaitingRequests() throws -> UserAuthenticationStateMachine {
        let configuration = SSHServerConfiguration(hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())], userAuthDelegate: delegate)
        var machine = UserAuthenticationStateMachine(role: .server(configuration), loop: loop, sessionID: ByteBuffer(bytes: [1, 2, 3]))
        _ = try machine.receiveServiceRequest(.init(service: "ssh-userauth"))
        machine.sendServiceAccept(.init(service: "ssh-userauth"))
        return machine
    }

    private func request(_ username: String) -> SSHMessage.UserAuthRequestMessage {
        .init(username: username, service: "ssh-connection", method: .keyboardInteractive(.init(languageTag: "", submethods: "")))
    }

    /// Starts a conversation and sends its first challenge, as the connection would.
    private func openConversation(_ machine: inout UserAuthenticationStateMachine, for username: String) throws {
        let reply = try XCTUnwrap(try machine.receiveUserAuthRequest(request(username)))
        loop.run()
        guard case .infoRequest(let challenge) = try reply.wait() else { return XCTFail("Expected a challenge") }
        machine.sendUserAuthInfoRequest(challenge)
    }

    func test_infoResponseWithoutAChallenge_isAProtocolViolation_notADelegateCall() throws {
        var machine = try serverAwaitingRequests()
        // A password request is outstanding — not a keyboard-interactive one.
        _ = try machine.receiveUserAuthRequest(.init(username: "alice", service: "ssh-connection", method: .password("x")))

        XCTAssertThrowsError(try machine.receiveUserAuthInfoResponse(.init(responses: ["424242"])))
        XCTAssertEqual(delegate.responsesSeen.count, 0)
    }

    func test_responseIsJudgedForTheUserWhoStartedTheConversation() throws {
        var machine = try serverAwaitingRequests()
        try openConversation(&machine, for: "alice")

        let verdict = try XCTUnwrap(try machine.receiveUserAuthInfoResponse(.init(responses: ["424242"])))
        loop.run()
        guard case .success = try verdict.wait() else { return XCTFail("Expected success") }
        XCTAssertEqual(delegate.responsesSeen.map(\.username), ["alice"])
        XCTAssertEqual(delegate.responsesSeen.map(\.responses), [["424242"]])
        XCTAssertEqual(machine.keyboardInteractiveUsername, "alice")
    }

    func test_secondConversationWhileOneIsOpen_isAProtocolViolation() throws {
        var machine = try serverAwaitingRequests()
        try openConversation(&machine, for: "alice")

        XCTAssertThrowsError(try machine.receiveUserAuthRequest(request("mallory")))
        XCTAssertEqual(machine.keyboardInteractiveUsername, "alice", "the open conversation keeps its user")
    }

    func test_afterAVerdict_aLateResponseIsAProtocolViolation() throws {
        var machine = try serverAwaitingRequests()
        delegate.verdict = .failure
        try openConversation(&machine, for: "alice")
        let verdict = try XCTUnwrap(try machine.receiveUserAuthInfoResponse(.init(responses: ["wrong"])))
        loop.run()
        guard case .failure(let failure) = try verdict.wait() else { return XCTFail("Expected failure") }
        machine.sendUserAuthFailure(failure)

        XCTAssertThrowsError(try machine.receiveUserAuthInfoResponse(.init(responses: ["again"])))
        XCTAssertEqual(delegate.responsesSeen.count, 1)
        XCTAssertNil(machine.keyboardInteractiveUsername)
    }
}
