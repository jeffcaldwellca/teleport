# Changelog

## 1.1.0

A large release: three new features, FTPS that works against common servers,
much faster transfers, and a round of safety fixes.

### New

- **Several servers at once.** Connecting to a favourite no longer disconnects
  the current one. Each session gets a tab above the remote pane; switch with
  ⇧⌘] / ⇧⌘[, close with ⇧⌘W. "Open in New Tab" opens a second session to the
  same server.
- **Folder sync.** Session ▸ Sync Folders… (⇧⌘S) compares the local pane's
  folder with the server's, shows what differs, and transfers only that —
  upload or download. Deleting what isn't in the source is optional and
  confirmed. Also available as `tport sync`, with `--dry-run`, `--delete`,
  `--exclude`, `--size-only` and `--json`.
- **SSH keys the way `ssh` uses them.** Passphrase-protected ed25519 and RSA
  keys (the passphrase can be kept in the Keychain), ECDSA keys, keys held by
  ssh-agent, and hosts imported from `~/.ssh/config`.
- **FTPS with self-signed certificates.** A certificate macOS doesn't trust is
  shown for approval once and remembered, instead of being refused outright.
  Trusted certificates are listed under Settings ▸ Security.
- **Browser:** Upload from the local pane's context menu, Go to Folder (⇧⌘G),
  optional Permissions and Owner columns, and real dates instead of
  "2 years ago".
- **`tport`:** `sync`, `trust list` / `trust forget`, `--version`; uses
  ssh-agent and `~/.ssh/config` by default; `get`/`put` keep modification
  times.

### Fixed

- **SFTP sent the password before the host key was approved.** An unknown
  server's key is now confirmed before any credentials leave the Mac.
- **A failed or cancelled download destroyed the file it was replacing.**
  Downloads are staged in a `.part` file and moved into place only when
  complete.
- **FTPS could log in but not list or transfer** against vsftpd and similar
  servers (data-channel TLS ordering, missing TLS session reuse, implicit mode),
  and about 1 in 20 FTPS downloads failed with a TLS read error.
- **A retried transfer could skip the "file already exists" question** and
  append to the existing file.
- **The app could quit unexpectedly** when a server closed an FTP connection.
- Servers without `MLSD` hid dotfiles and could show December files as dated
  next year; New Folder and Rename at the server root sent `//name`.
- The Settings concurrency stepper now updates its label.

### Faster

- SFTP transfers no longer wait for each 32 KB chunk to be acknowledged: over a
  30 ms link a 60 MB upload went from about 0.5 MB/s to about 20 MB/s, and a
  download from about 0.9 MB/s to about 9 MB/s.
- The transfer queue keeps one connection per worker instead of logging in for
  every file.
- Folder transfers accept 10,000 items (was 2,000).

### Changed — worth knowing before you upgrade

- Downloads started from the remote pane now land in **the folder the local
  pane is showing**, not `~/Downloads` (Settings ▸ Transfers still offers
  "Ask each time").
- The local pane opens in your **home folder** unless you chose another.
- **Deleting local files moves them to the Trash.**
- SSH fingerprints are shown in OpenSSH's form, to match `ssh-keygen -lf`.
- `tport` now reads `~/.ssh/config` and uses ssh-agent for `sftp://` URLs unless
  given `--no-ssh-config` / `--no-agent`. A URL whose host is also a config
  alias connects to that alias's `HostName`.
- Quitting with transfers in the queue asks first.

### Known limits

- RSA keys can only sign with SHA-1, which current OpenSSH servers refuse; use
  an ed25519 or ECDSA key. Passphrase-protected ECDSA key *files* aren't
  supported — add the key to ssh-agent instead.
- An ssh-agent approval prompt (Touch ID, a confirmation) that takes longer
  than 10 seconds fails the connection.
- Folder sync is one-way; it does not merge changes made on both sides.
