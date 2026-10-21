//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOCore

/// The user authentication modes available at this point in time.
///
/// Note: SSH certificate authentication is supported through the publicKey method,
/// not as a separate authentication method. When using certificates, the publicKey
/// method is used with a certified key.
public struct NIOSSHAvailableUserAuthenticationMethods: OptionSet {
    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let publicKey: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 0)
    public static let password: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 1)
    public static let hostBased: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 2)
    /// Teleport patch: RFC 4256 keyboard-interactive.
    public static let keyboardInteractive: NIOSSHAvailableUserAuthenticationMethods = .init(rawValue: 1 << 3)

    public static let all: NIOSSHAvailableUserAuthenticationMethods = [.publicKey, .password, .hostBased, .keyboardInteractive]
}

extension NIOSSHAvailableUserAuthenticationMethods {
    internal init(_ message: SSHMessage.UserAuthFailureMessage) {
        self = .init()

        for message in message.authentications {
            switch message {
            case "publickey":
                self.insert(.publicKey)
            case "password":
                self.insert(.password)
            case "hostbased":
                self.insert(.hostBased)
            case "keyboard-interactive":
                self.insert(.keyboardInteractive)
            default:
                // This is an unknown method, which we ignore.
                break
            }
        }
    }

    internal var strings: [Substring] {
        guard self != .init() else {
            return []
        }

        // We need an array.
        var methods = [Substring]()
        methods.reserveCapacity(3)

        if self.contains(.password) {
            methods.append("password")
        }
        if self.contains(.publicKey) {
            methods.append("publickey")
        }
        if self.contains(.hostBased) {
            methods.append("hostbased")
        }
        if self.contains(.keyboardInteractive) {
            methods.append("keyboard-interactive")
        }

        return methods
    }
}

extension NIOSSHAvailableUserAuthenticationMethods: Hashable {}

/// A specific request for user authentication. This type is the one observed from the server side. The
/// associated client side type is `NIOSSHUserAuthenticationOffer`.
public struct NIOSSHUserAuthenticationRequest {
    public var username: String

    public var request: Request

    public init(username: String, serviceName: String, request: Request) {
        self.username = username
        self.request = request
    }
}

public extension NIOSSHUserAuthenticationRequest {
    enum Request {
        case publicKey(PublicKey)
        case password(Password)
        case hostBased(HostBased)
        case none
    }
}

public extension NIOSSHUserAuthenticationRequest.Request {
    struct PublicKey {
        public var publicKey: NIOSSHPublicKey
        
        /// If the public key is a certificate, this contains the parsed certificate information.
        /// This includes critical options, extensions, and other certificate metadata.
        /// Certificate authentication in SSH uses the publicKey authentication method with
        /// a certified key, not a separate authentication method.
        public var certifiedKey: NIOSSHCertifiedPublicKey?

        public init(publicKey: NIOSSHPublicKey) {
            self.publicKey = publicKey
            self.certifiedKey = NIOSSHCertifiedPublicKey(publicKey)
        }
        
        public init(publicKey: NIOSSHPublicKey, certifiedKey: NIOSSHCertifiedPublicKey?) {
            self.publicKey = publicKey
            self.certifiedKey = certifiedKey
        }
    }

    struct Password {
        public var password: String

        public init(password: String) {
            self.password = password
        }
    }

    struct HostBased {
        init() {
            fatalError("HostBased authentication is currently unimplemented")
        }
    }
}

extension NIOSSHUserAuthenticationRequest: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.PublicKey: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.Password: Hashable {}

extension NIOSSHUserAuthenticationRequest.Request.HostBased: Hashable {}

/// A specific offer of user authentication. This type is the one used on the client side. The
/// associated server side type is `NIOSSHUserAuthenticationRequest`.
public struct NIOSSHUserAuthenticationOffer {
    public var username: String

    public var offer: Offer

    public init(username: String, serviceName: String, offer: Offer) {
        self.username = username
        self.offer = offer
    }
}

public extension NIOSSHUserAuthenticationOffer {
    enum Offer {
        case privateKey(PrivateKey)
        case password(Password)
        case hostBased(HostBased)
        /// Teleport patch: RFC 4256 keyboard-interactive.
        case keyboardInteractive(KeyboardInteractive)
        case none
    }
}

/// Teleport patch: what a server asks during keyboard-interactive
/// authentication (SSH_MSG_USERAUTH_INFO_REQUEST).
public struct NIOSSHKeyboardInteractiveChallenge: Hashable, Sendable {
    public struct Prompt: Hashable, Sendable {
        public var text: String
        /// Whether what the user types may be shown (false for passwords and codes).
        public var echo: Bool

        public init(text: String, echo: Bool) {
            self.text = text
            self.echo = echo
        }
    }

    public var name: String
    public var instruction: String
    public var languageTag: String
    public var prompts: [Prompt]

    public init(name: String, instruction: String, languageTag: String = "", prompts: [Prompt]) {
        self.name = name
        self.instruction = instruction
        self.languageTag = languageTag
        self.prompts = prompts
    }
}

/// Teleport patch: answers a challenge by completing the promise with one
/// response per prompt (in order); failing it aborts the login.
public typealias NIOSSHKeyboardInteractiveResponder = @Sendable (NIOSSHKeyboardInteractiveChallenge, EventLoopPromise<[String]>) -> Void

public extension NIOSSHUserAuthenticationOffer.Offer {
    /// Teleport patch.
    struct KeyboardInteractive {
        /// Comma-separated submethod names the client prefers; usually empty.
        public var submethods: String
        public var responder: NIOSSHKeyboardInteractiveResponder

        public init(submethods: String = "", responder: @escaping NIOSSHKeyboardInteractiveResponder) {
            self.submethods = submethods
            self.responder = responder
        }
    }
}

public extension NIOSSHUserAuthenticationOffer.Offer {
    struct PrivateKey {
        public var privateKey: NIOSSHPrivateKey
        public var publicKey: NIOSSHPublicKey

        public init(privateKey: NIOSSHPrivateKey) {
            self.privateKey = privateKey
            self.publicKey = privateKey.publicKey
        }

        /// Creates a private key offer with a certified public key.
        /// Certificate authentication uses the publicKey authentication method.
        public init(privateKey: NIOSSHPrivateKey, certifiedKey: NIOSSHCertifiedPublicKey) {
            self.privateKey = privateKey
            self.publicKey = NIOSSHPublicKey(certifiedKey)
        }
    }

    struct Password {
        public var password: String

        public init(password: String) {
            self.password = password
        }
    }

    struct HostBased {
        init() {
            fatalError("HostBased authentication is currently unimplemented")
        }
    }
}

extension SSHMessage.UserAuthRequestMessage {
    init(request: NIOSSHUserAuthenticationOffer, sessionID: ByteBuffer) throws {
        // We only ever ask for the ssh-connection service.
        self.username = request.username
        self.service = "ssh-connection"

        switch request.offer {
        case .privateKey(let privateKeyRequest):
            let dataToSign = UserAuthSignablePayload(
                sessionIdentifier: sessionID,
                userName: self.username,
                serviceName: self.service,
                publicKey: privateKeyRequest.publicKey
            )
            let signature = try privateKeyRequest.privateKey.sign(dataToSign)
            self.method = .publicKey(.known(key: privateKeyRequest.publicKey, signature: signature))
        case .password(let passwordRequest):
            self.method = .password(passwordRequest.password)
        case .keyboardInteractive(let request):
            // Teleport patch.
            self.method = .keyboardInteractive(.init(languageTag: "", submethods: request.submethods))
        case .hostBased:
            fatalError("Unsupported")
        case .none:
            self.method = .none
        }
    }
}

/// The outcome of a user authentication attempt.
public enum NIOSSHUserAuthenticationOutcome {
    case success
    case partialSuccess(remainingMethods: NIOSSHAvailableUserAuthenticationMethods)
    case failure
}

enum NIOSSHUserAuthenticationResponseMessage {
    case success
    case failure(SSHMessage.UserAuthFailureMessage)
    case publicKeyOK(SSHMessage.UserAuthPKOKMessage)
    /// Teleport patch: a keyboard-interactive challenge for the client.
    case infoRequest(SSHMessage.UserAuthInfoRequestMessage)
}

/// Teleport patch: what a server does next during keyboard-interactive.
public enum NIOSSHKeyboardInteractiveServerStep: Sendable {
    case challenge(NIOSSHKeyboardInteractiveChallenge)
    case success
    case partialSuccess(remainingMethods: NIOSSHAvailableUserAuthenticationMethods)
    case failure
}

extension NIOSSHUserAuthenticationResponseMessage {
    /// Teleport patch.
    init(_ step: NIOSSHKeyboardInteractiveServerStep, supportedMethods: NIOSSHAvailableUserAuthenticationMethods) {
        switch step {
        case .challenge(let challenge):
            self = .infoRequest(.init(
                name: challenge.name, instruction: challenge.instruction, languageTag: challenge.languageTag,
                prompts: challenge.prompts.map { .init(prompt: $0.text, echo: $0.echo) }
            ))
        case .success:
            self = .success
        case .partialSuccess(remainingMethods: let remaining):
            self = .failure(.init(authentications: remaining.strings, partialSuccess: true))
        case .failure:
            self = .failure(.init(authentications: supportedMethods.strings, partialSuccess: false))
        }
    }
}

extension NIOSSHUserAuthenticationResponseMessage {
    init(_ outcome: NIOSSHUserAuthenticationOutcome, supportedMethods: NIOSSHAvailableUserAuthenticationMethods) {
        switch outcome {
        case .success:
            self = .success
        case .partialSuccess(remainingMethods: let remaining):
            let message = SSHMessage.UserAuthFailureMessage(authentications: remaining.strings, partialSuccess: true)
            self = .failure(message)
        case .failure:
            let message = SSHMessage.UserAuthFailureMessage(authentications: supportedMethods.strings, partialSuccess: false)
            self = .failure(message)
        }
    }
}
