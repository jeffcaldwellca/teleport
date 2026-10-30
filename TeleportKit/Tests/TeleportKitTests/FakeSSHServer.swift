import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// An in-process SSH server for exercising `SFTPClient`'s handshake and
/// login against server policies the docker servers can't be configured
/// for: which authentication methods it advertises, how it answers an
/// offer (including a two-factor "partial success"), and which transport
/// algorithms it speaks. It never gets as far as SFTP.
final class FakeSSHServer {
    enum Reply {
        case accept
        case reject
        /// The offer was good but the server wants more (OpenSSH's
        /// `AuthenticationMethods publickey,keyboard-interactive`).
        case partialSuccess(remaining: NIOSSHAvailableUserAuthenticationMethods)
    }

    private final class AuthDelegate: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods
        private let reply: Reply
        private let lock = NSLock()
        private var _requests = 0
        /// Authentication requests answered (public key queries aren't:
        /// SwiftNIO SSH answers those itself).
        var requests: Int { lock.withLock { _requests } }

        init(accepts: NIOSSHAvailableUserAuthenticationMethods, reply: Reply) {
            self.supportedAuthenticationMethods = accepts
            self.reply = reply
        }

        func requestReceived(
            request: NIOSSHUserAuthenticationRequest,
            responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
        ) {
            lock.withLock { _requests += 1 }
            switch reply {
            case .accept:                           responsePromise.succeed(.success)
            case .reject:                           responsePromise.succeed(.failure)
            case .partialSuccess(let remaining):    responsePromise.succeed(.partialSuccess(remainingMethods: remaining))
            }
        }
    }

    let port: Int
    private let authDelegate: AuthDelegate
    /// Authentication requests the server has answered.
    var authenticationRequests: Int { authDelegate.requests }
    private let group: MultiThreadedEventLoopGroup
    private let listener: Channel

    /// - Parameters:
    ///   - accepts: the methods listed in every USERAUTH_FAILURE.
    ///   - reply: how each (well-formed) offer is answered.
    ///   - transportProtectionSchemes: the ciphers (and so the MAC names) the
    ///     server advertises; nil keeps SwiftNIO SSH's defaults.
    init(
        accepts: NIOSSHAvailableUserAuthenticationMethods,
        reply: Reply,
        transportProtectionSchemes: [NIOSSHTransportProtection.Type]? = nil
    ) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        authDelegate = AuthDelegate(accepts: accepts, reply: reply)
        var configuration = SSHServerConfiguration(
            hostKeys: [NIOSSHPrivateKey(ed25519Key: .init())],
            userAuthDelegate: authDelegate
        )
        if let transportProtectionSchemes {
            configuration.transportProtectionSchemes = transportProtectionSchemes
        }
        listener = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(role: .server(configuration),
                                      allocator: channel.allocator,
                                      inboundChildChannelInitializer: nil)
                    )
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        guard let port = listener.localAddress?.port else {
            throw POSIXError(.EADDRNOTAVAIL)
        }
        self.port = port
    }

    func stop() {
        try? listener.close().wait()
        try? group.syncShutdownGracefully()
    }
}
