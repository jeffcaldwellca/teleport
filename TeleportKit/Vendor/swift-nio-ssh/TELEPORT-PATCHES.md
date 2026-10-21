# swift-nio-ssh (Wellz26 fork), vendored

This is the `NIOSSH` library from [Wellz26/swift-nio-ssh](https://github.com/Wellz26/swift-nio-ssh)
0.3.6 (revision `a05e6bbe6b141ee68da3030e00275504c0595d4d`), the fork Citadel
depends on, Apache 2.0 licensed (see LICENSE.txt). `Tests/`, the example
executables, the DocC catalogue and the DocC plugin dependency are left out;
`Package.swift` is trimmed accordingly. The vendored Citadel next door
depends on it by path.

To upgrade, replace `Sources/NIOSSH`, `LICENSE.txt` and `README.md`, keep this
`Package.swift`, and re-apply the patch below. Every patched region is marked
`Teleport patch`.

## Patch: keyboard-interactive authentication (RFC 4256)

Upstream implements only `publickey`, `password` and (nominally) `hostbased`.
Servers that take passwords through PAM, and two-factor
`AuthenticationMethods` setups, need `keyboard-interactive` (GitHub issue #4).

- `NIOSSHAvailableUserAuthenticationMethods.keyboardInteractive`, read from
  and written to the `keyboard-interactive` method name; included in `.all`.
- `NIOSSHUserAuthenticationOffer.Offer.keyboardInteractive`, carrying
  submethods and a `NIOSSHKeyboardInteractiveResponder` that answers each
  `NIOSSHKeyboardInteractiveChallenge` through an `EventLoopPromise<[String]>`.
- Messages `SSH_MSG_USERAUTH_INFO_REQUEST` (60) and
  `SSH_MSG_USERAUTH_INFO_RESPONSE` (61), and the `keyboard-interactive`
  request body (`SSHMessages.swift`). Number 60 is also
  `SSH_MSG_USERAUTH_PK_OK`; `SSHPacketParser.expectedMethodSpecificMessage`
  says which to parse, set from the method of the request most recently sent
  (`SendsUserAuthMessages.writeUserAuthRequest`).
- Client state machine: a challenge received while a keyboard-interactive
  request is outstanding goes to the offer's responder (kept in a
  `KeyboardInteractiveSlot` shared by copies of the state machine); its
  answers are sent as INFO_RESPONSE and the request stays outstanding. A
  failed responder promise fails the connection.
- The client delegate hears about partial success:
  `nextAuthenticationType(availableMethods:partialSuccess:nextChallengePromise:)`,
  with a default that forwards to the two-argument method.
- Server side: `NIOSSHServerUserAuthenticationDelegate.keyboardInteractiveDelegate`
  (default nil, which refuses the method) and
  `NIOSSHServerKeyboardInteractiveDelegate`, which issues challenges and
  judges responses as `NIOSSHKeyboardInteractiveServerStep`s. Used by the
  test server; Teleport itself is only a client.

Covered by `KeyboardInteractiveMessageTests` (wire format) and
`SFTPClientKeyboardInteractiveTests` (end to end) in TeleportKit's test target.
