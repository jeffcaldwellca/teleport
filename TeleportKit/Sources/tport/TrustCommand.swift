import ArgumentParser
import Foundation
import TeleportKit

/// Inspect and edit what tport has been told to trust: SSH host keys
/// (`--accept-new-hostkey`) and FTPS certificates (`--accept-untrusted-cert`).
struct TrustCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trust",
        abstract: "List or forget trusted SSH host keys and FTPS certificates.",
        subcommands: [List.self, Forget.self],
        defaultSubcommand: List.self
    )

    struct Stores: ParsableArguments {
        @Option(name: .long, help: "Path to the known-hosts trust file. Defaults to ~/.teleport/known_hosts.json.")
        var knownHosts: String?

        @Option(name: .long, help: "Path to the trusted FTPS certificates file. Defaults to ~/.teleport/trusted_certs.json.")
        var trustedCerts: String?

        var hostKeysURL: URL { knownHosts.map { URL(fileURLWithPath: $0) } ?? AuthOptions.defaultKnownHostsURL }
        var certificatesURL: URL { trustedCerts.map { URL(fileURLWithPath: $0) } ?? AuthOptions.defaultTrustedCertsURL }

        /// (heading, store, how its fingerprints are conventionally written)
        var all: [(title: String, url: URL, store: SSHHostKeyStore, format: (String) -> String)] {
            [("SSH host keys", hostKeysURL, SSHHostKeyStore(storeURL: hostKeysURL), SSHKeyFingerprint.openSSH),
             ("FTPS certificates", certificatesURL, SSHHostKeyStore(storeURL: certificatesURL), SSHKeyFingerprint.display)]
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show every trusted host key and certificate.")
        @OptionGroup var stores: Stores

        func run() async throws {
            for (title, url, store, format) in stores.all {
                print("\(title) (\(url.path))")
                let hosts = await store.trustedHosts()
                if hosts.isEmpty { print("  (none)") }
                for host in hosts {
                    print("  \(host.id)  \(format(host.fingerprint))")
                }
            }
        }
    }

    struct Forget: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Stop trusting a host. The next connection asks again.",
            discussion: "`host:port` forgets that one entry; a bare `host` forgets every port, in both stores."
        )

        @Argument(help: "host or host:port")
        var host: String

        @OptionGroup var stores: Stores

        func run() async throws {
            try await runTport {
                var forgotten = 0
                for (_, _, store, _) in stores.all {
                    for entry in await store.trustedHosts() where matches(entry) {
                        try await store.forget(id: entry.id)
                        print("forgot \(entry.id)")
                        forgotten += 1
                    }
                }
                guard forgotten > 0 else { throw NothingTrusted(host: host) }
            }
        }

        private func matches(_ entry: SSHHostKeyStore.TrustedHost) -> Bool {
            entry.id == host || entry.host == host
        }
    }

    struct NothingTrusted: LocalizedError {
        let host: String
        var errorDescription: String? { "Nothing is trusted for \(host). Run `tport trust list` to see what is." }
    }
}
