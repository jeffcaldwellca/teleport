# Changelog

## Unreleased

### Fixed

- **Long upload queues no longer flash a CancellationError in the remote
  pane.** Each finished upload reloads the folder shortly after, and a
  completion that arrived while that reload was still listing cancelled it,
  leaving "The operation couldn’t be completed. (Swift.CancellationError
  error 1.)" and a Retry button in place of the file list. The reload now
  runs to the end and another follows once it's done. The local pane's
  reload after downloads had the same problem and is fixed too.
- **Resuming a paused transfer no longer appends to someone else's file.**
  A transfer paused before it had sent anything resumed by appending to
  whatever was already at the destination, without asking. It now starts
  clean and asks about the existing file first. A download retried after
  failing to connect likewise no longer replaces an existing file unasked.
- **Pause while the "file exists" dialog is up pauses the transfer** instead
  of marking it Skipped, and the question is asked again on resume.
- **Transfers added just as the queue finished no longer sit in the queue**
  until something else is added. With one transfer at a time this happened
  often, and Sync's delete step waited on it.
- **"Apply to all" no longer carries over to a later, unrelated batch**
  while a transfer from the earlier one is paused.
- **Two downloads whose names differ only in case** ("README" and "readme"
  from a case-sensitive server) no longer run at once into the same local
  file. The second waits, then asks like any other existing file.
- **Renaming onto an existing name is refused** instead of silently
  replacing the other file on the server.
- **The permissions sheet applies only what you change.** It no longer
  strips setuid, setgid and sticky bits, no longer sets a folder whose mode
  the server didn't report to 0644, and no longer sends an ownership change
  the server rejects when only the mode was edited.
- **Opening a folder you can't read no longer logs in again.** SFTP and FTP
  refusals ("permission denied", "no such file") are shown as such, rather
  than as a dropped connection followed by a full reconnect (and, on 2FA
  servers, another code prompt). A refused SFTP upload fails straight away
  instead of retrying.
- **The browser pane no longer jumps back** when a slow reload finishes
  after you've already opened another folder, and Retry after a failed
  navigation records it in history.
- **FTP:** a listing interrupted after it started no longer leaves every
  later reply one command behind; file and folder names with repeated or
  trailing spaces work; Windows/IIS servers without MLSD list their
  contents instead of showing every folder empty; servers with a Latin-1
  welcome message connect; folders are seen as existing when checking for
  conflicts; a timed-out session is detected before a conflict check
  instead of reading as "no such file".
- **Modification times on FTP** are no longer read in a Buddhist or
  Japanese calendar as a year five centuries away.
- **A damaged known_hosts.json no longer loses every pinned host key.**
  An unreadable host-key or certificate store is set aside next to the
  original instead of being written over. Likewise, one damaged saved
  connection no longer empties the whole list.
- **Uploading from a volume that disappears mid-transfer** fails the
  transfer instead of crashing the app.
- **Copying a large folder within the local pane** no longer freezes the
  window.
- **An SSH key typed into the connection editor is used** even after a
  different key was once picked with Browse.
- **SFTP sessions that drop are reconnected once,** not torn down twice
  when two things notice at the same moment.
- **tport:** `put --resume` and `get --resume` continue a partial file
  instead of skipping it and exiting 0; `get` into an existing folder (or a
  path ending in `/`) downloads into it, and `put` to a URL ending in `/`
  uploads into that folder; `sync --direction down` from an FTP server
  without MLSD no longer downloads most files again on every run.

## 1.2.0

### New

- **Keyboard-interactive SSH logins.** Servers that take passwords only
  through keyboard-interactive (PAM, the usual setup on a VPS) now log in
  with the configured password, with no extra prompt. Two-factor servers
  (`AuthenticationMethods publickey,keyboard-interactive` or
  `publickey,password`) work too: the key is accepted, then the second step
  is sent on the same connection, either the configured password or whatever
  the server asks for, shown in a sheet in the app and on the terminal in
  `tport`. A key is still never followed by the password unless the server
  asks for it as a second step. Fixes #4.

### Fixed

- **SFTP logins refused by a server's policy now say why.** A server that
  won't take the kind of credential offered used to produce a bare
  "Authentication failed" that looked like a wrong password or key. Teleport
  now reports what the server will still accept, for example that it
  accepts SSH keys but not passwords, or that the key was accepted but a
  second factor Teleport can't provide is required. A plain wrong password
  or unauthorised key still reads "Authentication failed".
- **Servers hardened to encrypt-then-MAC algorithms could not be reached.**
  With `MACs` restricted to the `*-etm@openssh.com` names (as ssh-audit and
  most hardening guides recommend) the key exchange failed before the host
  key was seen, although both sides would have used AES-GCM and never touched
  the MAC. Teleport now advertises OpenSSH's MAC names alongside its AES-GCM
  ciphers.

### Changed

- The SSH libraries, Citadel and the swift-nio-ssh fork it builds on, are now
  vendored under `TeleportKit/Vendor` so Teleport can patch them. swift-nio-ssh
  gains keyboard-interactive and reports partial success to the client.
  Citadel's authentication wrapper answered every round after the first
  itself, hiding the server's reply; its SFTP packet parser took any declared
  length, so a hostile server could make Teleport buffer without bound; and
  its directory listing followed the server's `realpath` and `readdir`
  answers for as long as the server kept them coming. See the
  `TELEPORT-PATCHES.md` in each.

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
