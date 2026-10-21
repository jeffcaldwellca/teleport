import Foundation
import NIOCore
import NIOSSH
import Citadel

/// Offers credentials to the server in order, one per authentication round,
/// skipping kinds the server says it won't accept.
///
/// SwiftNIO SSH asks again after every rejected offer (the vendored Citadel
/// forwards each of those calls; upstream only forwards the first). Even so,
/// `SFTPClient` gives each connection attempt a single offer and walks the
/// list itself, so a key file is only read — and its passphrase only asked
/// for — once everything ahead of it has been turned down.
final class SSHAuthSequence: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let lock = NSLock()
    private var remaining: [NIOSSHUserAuthenticationOffer.Offer]
    private var offered = false
    private var serverAccepts: NIOSSHAvailableUserAuthenticationMethods?

    init(username: String, offers: [NIOSSHUserAuthenticationOffer.Offer]) {
        self.username = username
        self.remaining = offers
    }

    /// The methods the server said it would still take when it turned down
    /// the last offer — nil until it has turned one down. Methods SwiftNIO
    /// SSH doesn't implement (keyboard-interactive, for one) are not in the
    /// set, so an empty set means "only things we can't do". The server's
    /// list after a two-factor "partial success" lands here too.
    var methodsServerStillAccepts: NIOSSHAvailableUserAuthenticationMethods? {
        lock.withLock { serverAccepts }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.withLock {
            // The first call reports every method as available; only the
            // answer to an actual offer says anything about the server.
            if offered { serverAccepts = availableMethods }

            while !remaining.isEmpty {
                let offer = remaining.removeFirst()
                // Skip anything the server has said it won't take (e.g. a
                // password on a keys-only server) rather than waste a try on it.
                guard availableMethods.contains(Self.method(of: offer)) else { continue }
                offered = true
                nextChallengePromise.succeed(
                    NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer)
                )
                return
            }
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
        }
    }

    private static func method(of offer: NIOSSHUserAuthenticationOffer.Offer) -> NIOSSHAvailableUserAuthenticationMethods {
        switch offer {
        case .privateKey: return .publicKey
        case .password:   return .password
        case .hostBased:  return .hostBased
        case .none:       return []
        }
    }
}
