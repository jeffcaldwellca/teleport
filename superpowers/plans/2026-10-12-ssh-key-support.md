# SSH Key Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Teleport and `tport` authenticate over SFTP with passphrase-protected key files, ECDSA key files, and keys held by `ssh-agent`, and reuse hosts from `~/.ssh/config`.

**Architecture:** Three new TeleportKit units with no UI knowledge — `SSHPrivateKeyFile` (key file → auth method), `SSHAgent` (agent protocol + agent-backed keys), `SSHConfig` (config parser) — joined by `SSHAuthSequence`, a single SwiftNIO SSH auth delegate that offers credentials in order. `SFTPClient` gets one new injected closure (`passphraseProvider`), following the existing `onUnknownHostKey` pattern; the app and `tport` each supply their own policy.

**Tech Stack:** Swift 5.9, Citadel 0.8+, SwiftNIO SSH, CryptoKit, SwiftUI, swift-argument-parser, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-12-ssh-key-support-design.md`

## Global Constraints

- macOS 14+, Swift 5.9; no new package dependencies.
- A password is never sent when a key file is configured (existing guarantee).
- `Connection` JSON saved by earlier versions must still decode; `useSSHAgent` absent ⇒ `false`.
- Agent offers are capped at 5 keys per connection.
- Passphrase is asked at most 3 times per connect.
- Unsupported cases fail with a message naming the way out: encrypted ECDSA file → `ssh-add`; RSA rejected → SHA-1 limitation.
- No `Co-Authored-By` trailers in commits.
- New source files need `xcodegen generate` (app target) — TeleportKit files are picked up by SwiftPM.

## Review Focus

1. **Wrong passphrase** — must re-ask (up to 3), never fall through to "unsupported key".
2. **Agent socket missing, stale or refusing** (`SSH_AUTH_SOCK` unset / path gone) with the agent enabled — connect must continue to the key file / password, not fail.
3. **Agent holding more keys than the server allows tries** — only the first 5 are offered, and the password is still tried afterwards.
4. **Key file with Windows line endings or a trailing blank line** — still parses.
5. **`~/.ssh/config` with `Include`, `Match`, quoted values, `=` separators, comments and mixed-case keywords** — unknown directives are skipped; nothing throws.

Each is pinned by a named test in the owning task below.

## File Structure

| File | Responsibility |
|---|---|
| `TeleportKit/Sources/TeleportKit/SSHPrivateKeyFile.swift` | Detect key type/encryption; parse into an auth offer |
| `TeleportKit/Sources/TeleportKit/SSHAgent.swift` | Agent wire protocol; agent-backed key types |
| `TeleportKit/Sources/TeleportKit/SSHAuthSequence.swift` | Ordered credential offers to the server |
| `TeleportKit/Sources/TeleportKit/SSHConfig.swift` | Parse and resolve `~/.ssh/config` |
| `TeleportKit/Sources/TeleportKit/SFTPClient.swift` | Build the sequence; passphrase retry loop |
| `TeleportKit/Sources/TeleportKit/Connection.swift` | `useSSHAgent` |
| `TeleportKit/Sources/tport/AuthOptions.swift` | Passphrase source, agent default, alias resolution |
| `Teleport/Services/PassphrasePrompt.swift` | Bridge connect flow → passphrase sheet; Keychain |
| `Teleport/Views/Sheets/PassphraseSheet.swift` | The sheet |
| `Teleport/Views/Sheets/SSHConfigImportSheet.swift` | Pick hosts to import |
| `scripts/start-test-servers.sh` | Generate test keys, authorise them on the SFTP container |

---

### Task 1: Key files

**Files:** Create `SSHPrivateKeyFile.swift`; Test `TeleportKit/Tests/TeleportKitTests/SSHPrivateKeyFileTests.swift`.

**Interfaces — Produces:**

```swift
public enum SSHPrivateKeyFile {
    public enum Failure: Error, Equatable { case passphraseRequired, wrongPassphrase, unsupported(String) }
    public enum Credential { case method(SSHAuthenticationMethod) /* ed25519, rsa */, key(NIOSSHPrivateKey) }
    public static func isEncrypted(_ keyText: String) -> Bool
    /// Parsed private key ready to offer for `username`.
    static func privateKey(from keyText: String, passphrase: String?) throws -> NIOSSHPrivateKey
    public static func isRSA(_ keyText: String) -> Bool
}
```

- [ ] Step 1 — failing tests. A helper runs `/usr/bin/ssh-keygen -q -t <type> [-b bits] -N <pass> -f <tmp>` and reads the file. Tests:
  `test_ed25519_unencrypted_parses`, `test_ed25519_encrypted_withPassphrase_parses`,
  `test_encrypted_withoutPassphrase_throwsPassphraseRequired`,
  `test_encrypted_wrongPassphrase_throwsWrongPassphrase` (Review Focus 1),
  `test_rsa_unencrypted_parses`, `test_ecdsa_p256_p384_p521_unencrypted_parse`,
  `test_ecdsa_encrypted_throwsUnsupportedNamingSshAdd`,
  `test_keyWithCRLFAndTrailingBlankLines_parses` (Review Focus 4),
  `test_notAKey_throwsUnsupported`. For each parsed key assert
  `String(openSSHPublicKey: key.publicKey)` equals the `.pub` file's first two fields.
- [ ] Step 2 — run `swift test --filter SSHPrivateKeyFileTests`; expect compile failure (type missing).
- [ ] Step 3 — implement. Encryption detection: decode the base64 body of
  `-----BEGIN OPENSSH PRIVATE KEY-----`, check magic `openssh-key-v1\0`, read
  `string ciphername`; encrypted ⇔ ciphername ≠ `none`. Key type: read the
  public-key blob's type string. ed25519 → `Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)`;
  RSA → `Insecure.RSA.PrivateKey(sshRsa:decryptionKey:)` wrapped with
  `NIOSSHPrivateKey(custom:)`; a Citadel throw while a passphrase was supplied
  → `.wrongPassphrase`. ECDSA unencrypted: private section =
  `uint32 check ×2, string keytype, string curve, string Q, mpint d, string comment`;
  build `P256/P384/P521.Signing.PrivateKey(rawRepresentation:)` from `d`
  left-padded/stripped to the curve size. PEM EC: `P*.Signing.PrivateKey(pemRepresentation:)`.
  Normalise `\r\n` → `\n` and trim before anything else.
- [ ] Step 4 — run the filter again; all pass. Run the whole package: `swift test`.
- [ ] Step 5 — commit "Parse passphrase-protected and ECDSA SSH key files".

### Task 2: Auth sequence, passphrase flow in SFTPClient, live key logins

**Files:** Create `SSHAuthSequence.swift`; modify `SFTPClient.swift`, `scripts/start-test-servers.sh`; Test `TeleportTests/SSHKeyAuthIntegrationTests.swift`.

**Interfaces — Consumes:** `SSHPrivateKeyFile.privateKey(from:passphrase:)`.
**Produces:**

```swift
final class SSHAuthSequence: NIOSSHClientUserAuthenticationDelegate {
    init(username: String, offers: [NIOSSHUserAuthenticationOffer.Offer])
    // offers one per call, skipping kinds the server doesn't list; nil when exhausted
}
// SFTPClient.init gains:
passphraseProvider: @escaping @Sendable (_ keyPath: String, _ retry: Bool) async -> String? = { _, _ in nil }
```

- [ ] Step 1 — script: generate into `/tmp/teleport-it-keys` (`ed25519`, `ed25519_enc` with passphrase `test-passphrase`, `ecdsa256`, `ecdsa384`, `ecdsa521`, `rsa`), `chmod 600`, and mount each `.pub` at `/home/testuser/.ssh/keys/<name>.pub:ro` on `teleport-it-sftp`.
- [ ] Step 2 — failing live tests (skip unless `TELEPORT_IT=1` and the key dir exists): one login + `listDirectory("/upload")` per key; `test_encryptedKey_asksForPassphrase_andRetriesAfterAWrongOne` (provider returns "nope" then the right one; asserts it was called with `retry == false` then `true`); `test_encryptedKey_providerDeclines_failsWithoutSendingPassword`; `test_keyConfigured_passwordIsNeverOffered` (wrong key + correct password ⇒ `authenticationFailed`).
- [ ] Step 3 — run them; expect failures ("Passphrase-protected SSH keys aren't supported yet" / unsupported ECDSA).
- [ ] Step 4 — implement: `buildAuthMethod` becomes `buildOffers() async throws -> [Offer]` (key file → `.privateKey(.init(privateKey:))`, with the passphrase loop: up to 3 asks, `retry` true after `.wrongPassphrase`, nil ⇒ throw `RemoteClientError.authenticationFailed`-class error "passphrase required"); password offer only when `sshKeyPath.isEmpty && !password.isEmpty`; connect with `.custom(SSHAuthSequence(...))`.
- [ ] Step 5 — run live + full suites; commit "Authenticate with encrypted and ECDSA key files".

### Task 3: ssh-agent

**Files:** Create `SSHAgent.swift`; modify `SSHAuthSequence.swift` (none needed — offers are generic), `SFTPClient.swift`, `Connection.swift`; Tests `TeleportKit/Tests/TeleportKitTests/SSHAgentTests.swift`, live tests appended to `SSHKeyAuthIntegrationTests.swift`.

**Interfaces — Produces:**

```swift
public struct SSHAgent: Sendable {
    public init(socketPath: String)
    public static var fromEnvironment: SSHAgent?            // SSH_AUTH_SOCK, nil if unset/empty
    struct Identity { let keyBlob: Data; let comment: String; var algorithm: String }
    func identities() throws -> [Identity]                 // SSH_AGENTC_REQUEST_IDENTITIES (11) → 12
    func sign(_ data: Data, with keyBlob: Data) throws -> Data   // 13 → 14, returns signature blob
    /// Keys the server-side negotiation here can use, RSA last, capped at `limit`.
    func privateKeys(limit: Int) -> [NIOSSHPrivateKey]     // [] on any agent error
}
// Connection: public var useSSHAgent: Bool = false  (custom decode: decodeIfPresent ?? false)
// SFTPClient.init gains: agent: SSHAgent? = nil   (used only when connection.useSSHAgent)
```

Wire format: every message is `uint32 length, byte type, payload`. Identities answer: `uint32 n` then n × (`string keyblob`, `string comment`). Sign request payload: `string keyblob, string data, uint32 flags(0)`. Failure reply type is 5.

Agent-backed key: generic over a phantom algorithm type so each SSH key type gets its own static prefix —
`AgentKey<A: AgentAlgorithm>: NIOSSHPrivateKeyProtocol`, `AgentPublicKey<A>`, `AgentSignature<A>`;
`write(to:)` emits the blob bytes that follow the type string, verbatim. Algorithms: `ssh-ed25519`, `ecdsa-sha2-nistp256/384/521`, `ssh-rsa`.

- [ ] Step 1 — failing unit tests against a scripted Unix-socket agent in the test target:
  `test_identities_parsesKeysAndComments`, `test_sign_returnsTheAgentsSignatureBlob`,
  `test_missingSocket_yieldsNoKeysInsteadOfThrowing` (Review Focus 2),
  `test_agentRefusal_yieldsNoKeys`, `test_privateKeys_areCappedAndPutRSALast` (Review Focus 3),
  `test_connection_savedWithoutUseSSHAgent_decodesAsFalse`.
- [ ] Step 2 — run; expect compile failure.
- [ ] Step 3 — implement `SSHAgent` (blocking `AF_UNIX` socket, `SO_NOSIGPIPE`, 30 s `SO_RCVTIMEO`/`SO_SNDTIMEO`, one connection per request), the key types, `Connection.useSSHAgent`, and in `SFTPClient.buildOffers` prepend `agent.privateKeys(limit: 5)` when `connection.useSSHAgent`.
- [ ] Step 4 — live tests: start `/usr/bin/ssh-agent -D -a <sock>` as a child process, `ssh-add` the ed25519 and ecdsa256 keys with `SSH_AUTH_SOCK=<sock>`; `test_agentKey_ed25519_logsIn`, `test_agentKey_ecdsa_logsIn`, `test_agentWithNoUsableKey_fallsBackToPassword`, `test_agentEnabledButSocketGone_stillLogsInWithPassword`.
- [ ] Step 5 — full suites; commit "Authenticate with keys from ssh-agent".

### Task 4: tport

**Files:** modify `TeleportKit/Sources/tport/AuthOptions.swift`; Tests in `TeleportTests/CLIIntegrationTests.swift`.

- [ ] Step 1 — failing CLI tests: `test_identity_encrypted_readsPassphraseFromEnvironment` (`TELEPORT_KEY_PASSPHRASE`), `test_identity_encrypted_withoutPassphraseOrTTY_failsWithAClearMessage`, `test_agent_isUsedByDefaultWhenNoIdentityOrPasswordIsGiven` (child env `SSH_AUTH_SOCK`), `test_noAgentFlag_disablesIt`.
- [ ] Step 2 — run; expect failures.
- [ ] Step 3 — implement: `--no-agent` flag; `useSSHAgent = !noAgent && identity == nil && resolvedPassword.isEmpty`; `passphraseProvider`: env var on the first ask, else `getpass("Passphrase for <path>: ")` when `isatty(STDIN_FILENO) != 0`, else nil. Help text mentions the env var.
- [ ] Step 4 — rebuild `tport`, run CLI tests; commit "tport: key passphrases and ssh-agent by default".

### Task 5: App — passphrase prompt, Keychain, agent toggle

**Files:** Create `Teleport/Services/PassphrasePrompt.swift`, `Teleport/Views/Sheets/PassphraseSheet.swift`; modify `KeychainService.swift`, `RemoteClientFactory.swift`, `ConnectionStore.swift`, `ConnectionEditorView.swift`, `ContentView.swift`; Test `TeleportTests/PassphrasePromptTests.swift`.

**Interfaces — Produces:**

```swift
// KeychainService: account "<uuid>.key-passphrase"
static func savePassphrase(_:for:) throws; static func loadPassphrase(for:) -> String?; static func deletePassphrase(for:)
@Observable @MainActor final class PassphrasePrompt {
    static let shared: PassphrasePrompt
    struct Request: Identifiable { let id: UUID; let keyPath: String; let isRetry: Bool }
    private(set) var pending: Request?
    func passphrase(for connectionID: UUID, keyPath: String, retry: Bool) async -> String?
    func submit(_ passphrase: String, remember: Bool); func cancel()
}
```

Flow in `passphrase(for:…)`: not a retry and a stored passphrase exists → return it; on retry delete the stored one; then prompt; `submit` saves when `remember`.

- [ ] Step 1 — failing tests (Keychain service name suffixed for tests so the real one isn't touched): `test_storedPassphrase_isReturnedWithoutPrompting`, `test_retry_discardsTheStoredPassphrase_andPrompts`, `test_cancel_returnsNil`, `test_submitWithRemember_storesIt`.
- [ ] Step 2 — run; expect compile failure.
- [ ] Step 3 — implement; sheet presented from `ContentView` and `ConnectionEditorView` (same pattern as `HostKeyConfirmationSheet`); "Use ssh-agent" toggle under the SSH Key row; `ConnectionStore.delete` removes the passphrase item; `xcodegen generate`.
- [ ] Step 4 — run app suite; commit "Ask for key passphrases, remember them in the Keychain, and add an ssh-agent toggle".

### Task 6: `~/.ssh/config` parser and tport alias resolution

**Files:** Create `SSHConfig.swift`; modify `AuthOptions.swift`; Tests `TeleportKit/Tests/TeleportKitTests/SSHConfigTests.swift`, one CLI test.

**Interfaces — Produces:**

```swift
public struct SSHConfig: Sendable {
    public struct Host: Equatable, Sendable { public var alias, hostName: String; public var user: String?; public var port: Int?; public var identityFile: String? }
    public init(text: String)
    public static func load(from url: URL = ~/.ssh/config) -> SSHConfig      // empty when unreadable
    public func resolve(_ alias: String) -> Host?                            // nil when no block matches
    public var hosts: [Host]                                                 // concrete aliases, file order
}
```

- [ ] Step 1 — failing tests: `test_resolve_readsHostNameUserPortIdentityFile`, `test_firstValueWins`, `test_wildcardBlockSuppliesDefaults`, `test_negatedPatternExcludes`, `test_hosts_listsConcreteAliasesOnly`, `test_identityFile_expandsTildeAndPercentTokens` (`~`, `%h`, `%u`... only `~` and `%d` expanded, others left), `test_unknownDirectivesQuotesEqualsCommentsAndCase_areTolerated` (Review Focus 5), `test_aliasWithoutHostName_usesTheAliasAsHostName`.
- [ ] Step 2 — run; expect compile failure.
- [ ] Step 3 — implement the parser; in `AuthOptions.makeClient`, for SFTP when the target host matches a config block: fill `HostName`, and `User`/`Port`/`IdentityFile` only where the URL/flags left the default. `--no-ssh-config` opts out.
- [ ] Step 4 — CLI test `test_sshConfigAlias_resolvesHostPortUserAndIdentity` with `--ssh-config <tmp file>` pointing at the test server; run; commit "Read ~/.ssh/config: resolve host aliases in tport".

### Task 7: App — import from SSH config

**Files:** Create `Teleport/Views/Sheets/SSHConfigImportSheet.swift`; modify `SidebarView.swift`, `ConnectionStore.swift`; Test `TeleportTests/SSHConfigImportTests.swift`.

**Interfaces — Produces:** `ConnectionStore.importHosts(_ hosts: [SSHConfig.Host]) -> Int` (count added; skips host+port+user duplicates; name = alias; SFTP; `sshKeyPath` = identity file; `useSSHAgent = identityFile == nil`).

- [ ] Step 1 — failing tests: `test_import_createsSFTPConnectionsNamedAfterTheAlias`, `test_import_skipsConnectionsThatAlreadyExist`, `test_import_withoutIdentityFile_turnsTheAgentOn` (store constructed over a throwaway `UserDefaults` suite).
- [ ] Step 2 — run; expect compile failure.
- [ ] Step 3 — implement; `ConnectionStore` takes an injectable `UserDefaults` (default `.standard`); sidebar "+" becomes a menu: "New Connection…", "Import from SSH Config…"; the sheet lists `SSHConfig.load().hosts` with checkboxes (already-present ones disabled); `xcodegen generate`.
- [ ] Step 4 — run app suite + full live run; commit "Import hosts from ~/.ssh/config".

## Self-review

- Spec coverage: §1 → Tasks 1, 2, 4, 5; §2 → Tasks 3, 4, 5; §3 → Tasks 6, 7; stated limits → messages asserted in Task 1 and documented in the README (added in Task 4's commit).
- Review Focus 1–5 each have a named test (Tasks 1, 3, 3, 1, 6).
- Names used across tasks: `passphraseProvider`, `useSSHAgent`, `SSHAgent.privateKeys(limit:)`, `SSHConfig.Host` — consistent.
