# Keyboard-interactive SSH authentication

## Why

Issue #4: a VPS refused both a key and a password with "Authentication
failed" while every other client got in. Two server policies, common on
internet-facing hosts, cause it: passwords accepted only through
`keyboard-interactive` (PAM), and two-factor `AuthenticationMethods` such as
`publickey,keyboard-interactive`. Teleport's SSH stack (Citadel on the
Wellz26 swift-nio-ssh fork) implements neither the method nor the
partial-success signal. Since 1.1.x Teleport at least explains the refusal;
this adds the method so those servers can actually be used.

## Goals

- Log in to servers that take passwords only via keyboard-interactive, with
  the password the user already configured and no extra prompt.
- Log in to two-factor servers: a key (or password) accepted as the first
  step, then keyboard-interactive (or a password) as the second, on the same
  connection.
- Show the server's prompts to the user when the password doesn't answer
  them (verification codes, custom PAM prompts): a sheet in the app, the
  terminal in `tport`.
- Keep behaving like `ssh`: never fall back to a password when a key is
  configured unless the server asks for it as a second step.

## Non-goals

- Server-side keyboard-interactive beyond what tests need.
- Password-change requests (`SSH_MSG_USERAUTH_PASSWD_CHANGEREQ`).
- Remembering second-factor answers.

## Anti-goals

- Sending the password to a server that didn't ask for it.
- Retrying a password the server already rejected through another method
  (that risks account lockout).

## How

**swift-nio-ssh (vendored at `TeleportKit/Vendor/swift-nio-ssh`, patched):**

- `NIOSSHAvailableUserAuthenticationMethods.keyboardInteractive`, parsed
  from and written to the `keyboard-interactive` method name.
- New offer `NIOSSHUserAuthenticationOffer.Offer.keyboardInteractive` with
  submethods and a responder that answers a
  `NIOSSHKeyboardInteractiveChallenge` (name, instruction, prompts with
  echo flags) through an `EventLoopPromise<[String]>`.
- Messages `SSH_MSG_USERAUTH_INFO_REQUEST` (60) and
  `SSH_MSG_USERAUTH_INFO_RESPONSE` (61). Number 60 is shared with
  `SSH_MSG_USERAUTH_PK_OK`; the auth state machine tells the packet parser
  which one is expected from the method of the outstanding request.
- Client state machine: on INFO_REQUEST while a keyboard-interactive request
  is outstanding, ask the responder and send INFO_RESPONSE; stay waiting.
  Any number of rounds. A failed responder promise fails the connection.
- The client delegate learns about partial success: a new
  `nextAuthenticationType(availableMethods:partialSuccess:nextChallengePromise:)`
  with a default forwarding to the existing two-argument method.
- Server side (for tests and completeness): an optional
  `NIOSSHServerKeyboardInteractiveDelegate` that issues challenges and
  judges responses; servers without it refuse the method.

**Citadel (vendored, patched):** the authentication wrapper forwards the
partial-success variant to custom delegates and knows the new offer.

**Teleport:**

- `SSHAuthSequence` offers one primary credential per connection as today,
  plus follow-ups (the password, then keyboard-interactive) that it offers
  only when the server reports partial success or stops listing the
  primary's kind — never after a plain rejection.
- Keyboard-interactive prompts are answered with the configured password
  when the challenge is a single hidden prompt and the password hasn't been
  tried on this connection yet; otherwise an `interactivePromptProvider`
  is asked. The provider's `nil` cancels the login with a clear message.
- The app shows a sheet listing the server's prompts (secure fields for
  hidden ones); `tport` prints them on the terminal and reads answers with
  `getpass`, giving up when there is no terminal.
- Refusal explanations drop "which Teleport doesn't support yet".

## Left to the builder

Exact wording of messages and sheet layout; limits on rounds (a sane cap,
e.g. 10 challenges per connection).
