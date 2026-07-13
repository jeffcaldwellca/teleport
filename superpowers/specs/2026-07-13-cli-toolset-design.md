# Teleport CLI toolset

## Problem

Teleport is a macOS SwiftUI FTP/FTPS/SFTP client. All transfer and file-management
capability lives behind GUI interaction, so it can't be driven from shell scripts,
cron jobs, or CI/CD pipelines. This adds a command-line tool, `tport`, that exposes
full remote file management (browse, transfer, and manage files on FTP/FTPS/SFTP
servers) for scripted/automated use, sharing its protocol implementation with the
GUI app rather than duplicating it.

## Non-goals

- Diff-based sync/mirror (rsync-style skip-unchanged, `--delete`). v1 ships
  recursive copy only; sync can be a fast-follow once real usage patterns emerge.
- Reusing the GUI's saved `ConnectionStore`/Keychain entries. The CLI is fully
  stateless with respect to connections — every invocation supplies its target
  and credentials explicitly. (It does maintain its own small persistent
  state for SSH host key trust — see below.)
- Homebrew tap/formula or other distribution polish. The CLI ships as a binary
  built alongside the app; installing it onto `PATH` is a manual step for now.

## Architecture

Extract the protocol-agnostic parts of `Teleport/Services` and `Teleport/Models`
into a new local Swift package, **TeleportKit**:

- `Connection`, `FileItem`, `RemotePath`
- `RemoteClient` protocol, `RemoteClientError`, `RemoteClientFactory`
- `FTPClient`, `FTPError`, `FTPListingParser`
- `SFTPClient`
- `SSHHostKeyStore`, `SSHKeyFingerprint`, `CapturingHostKeyValidator`, `HostKeyMismatchError`

Two consumers depend on `TeleportKit`:

- **`Teleport`** (existing SwiftUI app target) — imports the package instead of
  compiling these files directly. GUI-only code stays in the app target:
  `ConnectionStore`, `KeychainService`, `BookmarkStore`, `HostKeyConfirmation`,
  `LocalFileService`, `RemoteEditManager`, `TransferTask`/`TransferQueueViewModel`,
  all Views/ViewModels.
- **`TeleportCLI`** (new executable target, product name `tport`) — depends on
  `TeleportKit` and Apple's `swift-argument-parser`. Not sandboxed (no
  entitlements file), since a sandboxed process can't read arbitrary
  script-supplied paths without a user-driven file picker.

`SFTPClient` currently reaches out to two GUI-only singletons: `BookmarkStore`
(sandboxed key-file access) and `HostKeyConfirmation` (SwiftUI TOFU dialog).
Both become injectable, with defaults that suit the CLI:

- A `keyReader: @Sendable (URL) async throws -> Data` closure, defaulting to a
  plain `Data(contentsOf:)` read. The app target supplies a closure that tries
  `BookmarkStore` first, falling back to direct read (today's exact behavior).
- An `onUnknownHostKey: @Sendable (String, Int, String) async -> Bool` closure
  (host, port, fingerprint → trust?), defaulting to `false` (fail closed). The
  app target supplies a closure wrapping `HostKeyConfirmation.shared.confirm`.
- `SSHHostKeyStore` changes from a hardcoded-path singleton to an instance
  configurable with a `storeURL`. `SSHHostKeyStore.shared` keeps the app's
  existing `Application Support/Teleport/known_hosts.json` path (no behavior
  change, no migration). The CLI creates its own instance pointed at
  `~/.teleport/known_hosts.json` by default, overridable with `--known-hosts`.

`RemoteClientError` gets two new cases — `hostKeyUntrusted` and
`hostKeyMismatch` — replacing the ad hoc `.unknown(...)` strings currently
thrown from the host-key paths in `SFTPClient.connect`. This lets the CLI map
host-key failures to a distinct exit code without string-matching error text;
the GUI is unaffected since it only ever displays `localizedDescription`.

`project.yml` gains a local Swift package reference and the `TeleportCLI`
target; `xcodegen generate` regenerates the `.xcodeproj` as usual.

## Command surface

Every command takes a URL — `sftp://user@host:port/path`, `ftp://...`,
`ftps://...` — and is fully stateless:

```
tport ls    <url>                 [--recursive] [--json]
tport stat  <url>                 [--json]
tport get   <remote-url> <local>  [--recursive] [--resume] [--overwrite|--skip|--if-newer]
tport put   <local> <remote-url>  [--recursive] [--resume] [--overwrite|--skip|--if-newer]
tport mkdir <url>                 [-p]
tport rm    <url>                 [--recursive]
tport mv    <src-url> <dst-url>
tport chmod <octal> <url>
tport chown <owner> <group> <url> # SFTP only; FTP SITE CHOWN when the server supports it
tport test  <url>                 # connectivity/auth check only, no output on success
```

Shared auth flags: `--password`, `TELEPORT_PASSWORD` env var, or
`--password-stdin` (reads one line from stdin — avoids the password appearing
in `ps`/shell history). SFTP key auth: `--identity <keyfile>`, with
`TELEPORT_KEY_PASSPHRASE` env for encrypted keys (passphrase-protected keys
are currently unsupported by `SFTPClient` regardless — the CLI inherits that
limitation and surfaces the same error).

Recursive `get`/`put` reuse the existing local-tree-walk and remote
breadth-first-walk logic (ported into `TeleportCLI` since today's version
lives in `TransferQueueViewModel`, which stays GUI-only) including the
`folderTransferLimit` safety cap, overridable with `--max-items`.

Conflict handling for `get`/`put`: `--overwrite` (always replace),
`--skip` (never replace, default), `--if-newer` (replace only if the source
is newer — mirrors `ConflictResolution.overwriteIfNewer`'s comparison logic).
No interactive dialog — a conflict without an explicit flag resolves to
`--skip` and a warning line on stderr, not a hang.

## Host key handling

Default: fail closed. An unknown host key produces an error naming the
fingerprint and exits with code `6`; re-running with `--accept-new-hostkey`
trusts and saves it to the known-hosts file. A *changed* key (mismatch
against a saved fingerprint) always hard-fails — there's no override flag,
matching `ssh`'s behavior for a possible MITM. `--known-hosts <path>`
overrides the default `~/.teleport/known_hosts.json` location (useful for
CI/ephemeral runners that want a throwaway trust store).

## Output & exit codes

Default output is human-readable text. `get`/`put` show a live progress line
on stderr when stderr is a TTY, auto-suppressed otherwise (piping/cron).
`--json` on `ls`/`stat` emits structured JSON on stdout. `--quiet` suppresses
all non-error stdout, leaving just the exit code and any error on stderr.

Exit codes: `0` success · `1` generic transfer/runtime failure ·
`2` usage/argument error · `3` auth failure · `4` not found ·
`5` connection/network error · `6` host key unknown or mismatched.
Documented in `--help` and enforced by a single error → exit-code mapping
function so every subcommand behaves consistently.

## Testing

- Unit tests (no live server): URL parsing (scheme/user/host/port/path),
  error → exit-code mapping, known-hosts file read/write/trust-on-accept.
- Integration tests reusing the existing docker FTP/SFTP containers
  (`teleport-it-ftp`, `teleport-it-sftp` — see `TransferIntegrationTests.swift`
  for exact setup) exercising each subcommand against live servers: listing,
  put/get including resume of an interrupted transfer, conflict flags,
  chmod/chown where supported, and host-key fail-closed / trust-on-accept
  behavior against a throwaway known-hosts file.
- **Not run as part of this change**: the docker-based integration pass, per
  explicit instruction to proceed to completion without that verification
  step. The tests are written; someone needs to actually run them against the
  live containers before trusting the protocol-level behavior (resume,
  conflict resolution, host-key trust) end to end.

## Packaging

`scripts/build-release.sh` additionally builds the `tport` executable
(Release configuration) and copies it into `build/`, alongside `Teleport.app`.
Installing it onto `PATH` (e.g. `ln -s build/tport /usr/local/bin/tport`)
remains a manual step — no formula/tap in this change.
