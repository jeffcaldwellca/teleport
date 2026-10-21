import Foundation
import NIOCore
import NIOSSH
import Citadel

/// Offers credentials to the server over one connection: a primary
/// credential, then — only when the server got part-way with it — follow-ups.
///
/// SwiftNIO SSH asks for the next offer after every reply (the vendored
/// Citadel forwards each of those calls; upstream only forwards the first).
/// `SFTPClient` still gives each connection attempt one primary credential
/// and walks its list itself, so a key file is only read — and its passphrase
/// only asked for — once everything ahead of it has been turned down.
///
/// Follow-ups are offered when the server reports *partial success* (the
/// primary was accepted as the first of several required steps) or when it
/// stops listing the primary's kind at all (a password sent to a server that
/// takes passwords only through keyboard-interactive). After a plain
/// rejection — the kind is still listed — the credential itself was wrong,
/// and nothing else is sent: retrying the same password another way risks
/// locking the account.
final class SSHAuthSequence: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private let lock = NSLock()
    private let primary: NIOSSHUserAuthenticationOffer.Offer
    private var followUps: [NIOSSHUserAuthenticationOffer.Offer]
    private var offered: [NIOSSHUserAuthenticationOffer.Offer] = []
    private var serverAccepts: NIOSSHAvailableUserAuthenticationMethods?
    private var sawPartialSuccess = false

    init(username: String, primary: NIOSSHUserAuthenticationOffer.Offer, followUps: [NIOSSHUserAuthenticationOffer.Offer] = []) {
        self.username = username
        self.primary = primary
        self.followUps = followUps
    }

    /// The methods the server said it would still take when it turned down
    /// the last offer — nil until it has turned one down. Methods SwiftNIO
    /// SSH doesn't implement (host-based, in practice) are not in the set.
    var methodsServerStillAccepts: NIOSSHAvailableUserAuthenticationMethods? {
        lock.withLock { serverAccepts }
    }

    /// The offer the server answered last; the primary until a follow-up went out.
    var lastOffer: NIOSSHUserAuthenticationOffer.Offer {
        lock.withLock { offered.last ?? primary }
    }

    /// Whether the server accepted the primary as the first of several steps.
    var primaryWasAccepted: Bool {
        lock.withLock { sawPartialSuccess }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        nextAuthenticationType(availableMethods: availableMethods, partialSuccess: false, nextChallengePromise: nextChallengePromise)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        partialSuccess: Bool,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.withLock {
            // The first call reports every method as available; only the
            // answer to an actual offer says anything about the server.
            guard let last = offered.last else {
                offered.append(primary)
                nextChallengePromise.succeed(offer(primary))
                return
            }
            serverAccepts = availableMethods
            if partialSuccess { sawPartialSuccess = true }

            let lastKindStillTaken = availableMethods.contains(Self.method(of: last))
            guard partialSuccess || !lastKindStillTaken else {
                // Turned down outright: the credential was wrong. Stop here.
                nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
                return
            }
            while !followUps.isEmpty {
                let next = followUps.removeFirst()
                // Skip anything the server has said it won't take.
                guard availableMethods.contains(Self.method(of: next)) else { continue }
                offered.append(next)
                nextChallengePromise.succeed(offer(next))
                return
            }
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
        }
    }

    private func offer(_ offer: NIOSSHUserAuthenticationOffer.Offer) -> NIOSSHUserAuthenticationOffer {
        NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer)
    }

    static func method(of offer: NIOSSHUserAuthenticationOffer.Offer) -> NIOSSHAvailableUserAuthenticationMethods {
        switch offer {
        case .privateKey:          return .publicKey
        case .password:            return .password
        case .keyboardInteractive: return .keyboardInteractive
        case .hostBased:           return .hostBased
        case .none:                return []
        }
    }
}
