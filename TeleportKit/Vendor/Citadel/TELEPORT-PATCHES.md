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
