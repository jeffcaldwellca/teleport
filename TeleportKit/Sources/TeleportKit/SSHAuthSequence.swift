import NIOCore
import NIOSSH
import Citadel

/// Offers credentials to the server in order, one per authentication round,
/// skipping kinds the server says it won't accept.
///
/// SwiftNIO SSH asks again after every rejected offer, but Citadel's wrapper
/// passes only the first request through to a custom delegate — so in
/// practice `SFTPClient` gives each connection attempt a single offer and
/// walks the list itself.
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
