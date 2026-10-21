# Citadel, vendored

This is [orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel) 0.12.1
(revision `ae8562f895de06ccb86fdb1cbb65fd99c8976e12`), MIT licensed (see
LICENSE), with `Tests/`, `Examples/` and the `Dockerfile` left out. Its own
dependencies (SwiftNIO, the Wellz26 fork of swift-nio-ssh, swift-crypto, …)
are still fetched from upstream by `Package.swift`.

It is vendored so that `TeleportKit` can carry the patch below; nothing else
is changed. To upgrade, replace `Sources/`, `Package.swift`, `LICENSE` and
`README.md` with the new release and re-apply the patch.

## Patches

### `Sources/Citadel/SSHAuthenticationMethod.swift` — consult a custom delegate on every round

`SSHAuthenticationMethod.custom(_:)` wraps a `NIOSSHClientUserAuthenticationDelegate`.
Upstream consumes the wrapped delegate on the first `nextAuthenticationType`
call and answers every later call with `allAuthenticationOptionsFailed`, so
the delegate never sees the server's USERAUTH_FAILURE reply — the list of
methods it will still accept. Teleport's `SSHAuthSequence` needs that list to
tell a wrong password apart from a server that doesn't take passwords at all,
and a bad key from a key that was accepted as the first of two required steps
(GitHub issue #4). The patch forwards every call to a lone custom delegate.

### `Sources/Citadel/SFTP/SFTPMessageParser.swift` — bound the packet length

The parser read a 32-bit length and asked for more data until that many
bytes had arrived, so a server could make the client buffer towards a
4 GiB packet, and a declared length of zero could never complete. Lengths
of zero or above `SFTPMessageParser.maximumPacketLength` (1 MiB; OpenSSH's
sftp-server caps its own at 256 KiB) now fail the connection with the new
`SFTPError.invalidPacketLength`.

### `Sources/Citadel/SFTP/Client/SFTPClient.swift` — bound the loops a server drives

`listDirectory` re-asked `realpath` until the answer stopped changing and
read `readdir` until EOF, both for as long as the server cared to keep
going. The realpath loop now gives up after `maximumRealPathRounds` (8) with
`SFTPError.invalidResponse`; the readdir loop stops with the new
`SFTPError.directoryListingTooLarge` once a listing exceeds `maximumEntries`
(a new parameter, default `defaultMaximumDirectoryEntries` = 1,000,000;
an empty reply counts as one entry so endless empty replies end too).

Both are covered by `SFTPMessageParserTests` and `SFTPListingLimitTests`
in TeleportKit's test target.
