import NIOCore
import NIOSSH
import Citadel

/// Offers a fixed list of credentials to the server, one per round, in order
/// — the way `ssh` works through agent keys, identity files and then a
/// password. Citadel's built-in methods each offer a single credential.
///
/// SwiftNIO SSH calls this on the connection's event loop, once at the start
/// and again after every rejected offer.
final class SSHAuthSequence: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var remaining: [NIOSSHUserAuthenticationOffer.Offer]

    init(username: String, offers: [NIOSSHUserAuthenticationOffer.Offer]) {
        self.username = username
        self.remaining = offers
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while !remaining.isEmpty {
            let offer = remaining.removeFirst()
            // Skip anything the server has said it won't take (e.g. a
            // password on a keys-only server) rather than waste a try on it.
            guard availableMethods.contains(Self.method(of: offer)) else { continue }
            nextChallengePromise.succeed(
                NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer)
            )
            return
        }
        nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
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
