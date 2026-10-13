# SSH key support — design

Date: 2026-10-12
Status: approved to build ("spec, plan, build"); not separately reviewed

## Goal

Someone who already uses `ssh` on their Mac should be able to connect to the
same servers from Teleport and `tport` without changing how their keys are
set up. Today SFTP authentication accepts a password or an **unencrypted**
ed25519/RSA key file, and nothing else.

Four gaps, in order of how often they block people:

1. Passphrase-protected key files are rejected outright.
2. Keys held by `ssh-agent` (including macOS Keychain-backed ones) can't be used.
3. ECDSA key files are rejected.
4. Hosts already described in `~/.ssh/config` have to be retyped.

## What the libraries allow

Checked against the pinned Citadel / SwiftNIO SSH sources, not assumed:

- Citadel decrypts OpenSSH-format ed25519 and RSA keys given a passphrase
  (`init(sshEd25519:decryptionKey:)`, `init(sshRsa:decryptionKey:)`).
- Citadel has ECDSA *authentication* (`.p256/.p384/.p521`) but no ECDSA
  key-file parser, and its OpenSSH container parser and bcrypt KDF are internal.
- SwiftNIO SSH accepts custom private-key types whose `signature(for:)` is
  called synchronously — enough to delegate signing to an agent.
- For a custom key, SwiftNIO SSH writes one name as both the auth algorithm
  and the key-blob type. RSA with SHA-2 needs those to differ
  (`rsa-sha2-512` vs `ssh-rsa`), so it cannot be expressed.

Consequences, stated to the user rather than hidden:

- **Encrypted ECDSA key files are not supported.** The message points at
  `ssh-add`, after which the key works through the agent.
- **RSA keys sign with SHA-1 only** (file or agent), which OpenSSH 8.8+
  rejects by default. This is existing behaviour; it is documented and the
  auth-failure message for an RSA key says so. Fixing it needs a patched
  SwiftNIO SSH and is out of scope.

## Design

### 1. Key files — `SSHPrivateKeyFile` (TeleportKit)

One type owns "turn a key file into an authentication method":

```swift
public enum SSHPrivateKeyFile {
    public enum Failure: Error { case passphraseRequired, wrongPassphrase, unsupported(String) }
    public static func isEncrypted(_ text: String) -> Bool
    static func authentication(username: String, keyText: String, passphrase: String?) throws -> SSHAuthenticationMethod
}
```

- ed25519 / RSA, OpenSSH format, with or without a passphrase → Citadel.
- ECDSA P-256/384/521: unencrypted OpenSSH format (small parser of the
  `openssh-key-v1` container, cipher `none` only) and unencrypted PEM
  (`BEGIN EC PRIVATE KEY` / `BEGIN PRIVATE KEY`, via CryptoKit).
- Encrypted and no passphrase supplied → `.passphraseRequired`; supplied but
  decryption fails → `.wrongPassphrase`.

`SFTPClient` gains one injected dependency, mirroring `onUnknownHostKey`:

```swift
passphraseProvider: @Sendable (_ keyPath: String, _ retry: Bool) async -> String? = { _, _ in nil }
```

It is called only when the key is encrypted; `retry` is true after a wrong
passphrase (asked at most three times). Returning nil cancels the connect.

- **App:** looks in the Keychain first (item per connection, alongside the
  password); otherwise shows a passphrase sheet with "Remember in Keychain".
  A remembered passphrase that turns out wrong is deleted and re-asked.
- **tport:** `TELEPORT_KEY_PASSPHRASE`, else an interactive no-echo prompt
  when stdin is a terminal, else fail with a clear message.

### 2. ssh-agent — `SSHAgent` (TeleportKit)

- `SSHAgent(socketPath:)` speaks the agent protocol over the Unix socket in
  `SSH_AUTH_SOCK`: list identities, sign. Blocking I/O with a timeout.
- Each listed key becomes a custom SwiftNIO SSH private key whose
  `signature(for:)` asks the agent. Key and signature bodies are passed
  through verbatim, so one generic type covers ed25519 and the three ECDSA
  curves. RSA agent keys are offered last, with the SHA-1 caveat above.
- Credentials are tried in order, one per connection attempt, moving on when
  the server rejects one. (As built: Citadel consults a custom authentication
  delegate only once per connection, so the sequence can't run inside a
  single connection as first designed. The usual case — the first key is
  accepted — still costs one connection.) The order:
  1. agent keys, when the agent is enabled (at most 5, to stay under the
     server's `MaxAuthTries`);
  2. the configured key file, if any;
  3. the password, only when no key file is configured and it is non-empty.
  Rule 3 keeps today's guarantee that a password is never sent when the user
  set up a key.
- `Connection` gains `useSSHAgent: Bool` (decodes as `false` when absent, so
  saved connections behave exactly as before). The editor shows a
  "Use ssh-agent" toggle for SFTP.
- **tport** uses the agent by default when `SSH_AUTH_SOCK` is set and neither
  `--identity` nor a password was given — the way `ssh` behaves. `--no-agent`
  turns it off.

Signing blocks one SwiftNIO event-loop thread for the duration of the agent
round trip. That is microseconds normally; an agent that prompts (Touch ID,
confirmation) holds it for as long as the prompt is up. Accepted.

### 3. `~/.ssh/config` — `SSHConfig` (TeleportKit)

A parser for the subset that matters: `Host` (with `*`/`?` patterns and `!`
negation), `HostName`, `User`, `Port`, `IdentityFile`. First value wins, as in
OpenSSH. `Include`, `Match` and everything else are ignored, not errors.

- `SSHConfig.hosts` — concrete aliases (no wildcards), each resolved against
  the wildcard blocks.
- **App:** "Import from SSH Config…" in the sidebar's add menu lists those
  hosts with checkboxes and creates SFTP connections (alias as the name),
  skipping ones that already exist with the same host/port/user.
- **tport:** `sftp://alias/path` resolves `HostName`, `User`, `Port` and
  `IdentityFile` from the config for anything the URL or flags didn't specify.

## Not doing

- Encrypted ECDSA key files; RSA SHA-2 signatures (see above).
- Keyboard-interactive auth, certificates, `ProxyJump`, FIDO keys read from
  files (FIDO keys in the agent are not offered either: their key types are
  unknown to the server-side negotiation here).
- Changing the default: existing and new connections start with the agent off.

## Testing

- Unit: key detection and parsing against keys generated in the test by
  `ssh-keygen` (ed25519 ± passphrase, ECDSA ×3, RSA); config parsing;
  agent wire format against a scripted in-process agent socket.
- Live (`scripts/start-test-servers.sh`): the SFTP container gets the test
  public keys; tests log in with each key type from a file, with a
  passphrase, and through a real `ssh-agent` started for the test.
