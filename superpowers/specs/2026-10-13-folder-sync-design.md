# Folder sync — design

Date: 2026-10-13
Status: approved to build ("spec plan build"); not separately reviewed

## Goal

Bring a remote folder up to date with a local one (or the reverse) by
transferring only what differs — the deploy-a-site and pull-a-backup
workflows — with a preview before anything is changed. In the app and as
`tport sync`.

Today the only options are transferring the whole folder again or picking
through it by hand.

## Scope

**One-way mirror, in either direction.** The source is the truth; the
destination is brought in line with it.

- *Upload*: local → remote. *Download*: remote → local.
- A file is transferred when it is missing at the destination, its size
  differs, or the source is newer.
- Optionally, files that exist only at the destination are deleted.

**Not two-way sync.** Merging changes made on both sides needs a record of
the last synced state to tell "changed here" from "deleted there"; without
one it guesses, and guesses wrong destructively. Out of scope.

## Comparison rules

For each relative path present on either side:

| Source | Destination | Action |
|---|---|---|
| file | missing | transfer |
| file | file, different size | transfer |
| file | file, same size, source newer by more than the tolerance | transfer |
| file | file, same size, otherwise | nothing (in sync) |
| file | directory (or the reverse) | **skip**, reported as a type conflict — never replaced automatically |
| missing | file or directory | delete, only when deletion is on; otherwise nothing |
| directory | missing | create |

- **Tolerance** is 2 seconds, widened to 60 seconds when the remote time has
  no seconds (FTP servers that only offer `LIST` report minutes). Without
  this, such servers would re-transfer everything on every run.
- **Size only** mode ignores times, for servers whose clocks can't be trusted.
- After a transfer the destination's modification time is set to the
  source's (as the transfer queue already does), so the next comparison
  finds the pair in sync wherever the server allows it.
- **Excluded** names (`.DS_Store` always; more by pattern) are ignored on
  both sides: never transferred, and never deleted from the destination.
- Symlinks are skipped on both sides, as in folder transfers.
- Names that are unsafe to create locally are skipped and reported.

## Safety

- Nothing is changed until the plan has been produced. The app shows it;
  `tport sync --dry-run` prints it.
- Deletion is off unless asked for.
- **An empty source never deletes.** If the source has no entries at all and
  deletion is on, the plan is refused: an unmounted volume or a mistyped
  path must not empty a server. (`tport sync --allow-empty-source` overrides.)
- A source folder that doesn't exist is an error, not "empty".
- More than 10,000 entries on a side is an error before anything is done.
- Deletions run after transfers, deepest paths first; local deletions go to
  the Trash.

## Design

### TeleportKit — `FolderSync.swift`

Pure and UI-free:

```swift
public struct SyncEntry { relativePath, isDirectory, size: Int64?, modified: Date?, modifiedHasSeconds: Bool }
public enum SyncDirection { case upload, download }
public struct SyncOptions { deleteExtraneous, sizeOnly, excludes: [String], allowEmptySource }
public struct SyncAction { relativePath, kind: .transfer/.createDirectory/.delete/.skip(reason), isDirectory, size, reason: String }
public struct SyncPlan { direction, actions; transfers/deletions/skips/totalBytes; isEmpty }
public enum FolderSync {
    static func plan(local: [SyncEntry], remote: [SyncEntry], direction:, options:) throws -> SyncPlan
    static func scanLocal(_ root: URL, excludes:, limit:) throws -> [SyncEntry]
    static func scanRemote(_ client: RemoteClient, root: String, excludes:, limit:) async throws -> [SyncEntry]
    static func matches(exclude pattern: String, relativePath: String) -> Bool
}
```

Exclude patterns are globs (`*`, `?`): one without `/` matches any path
component (`node_modules`, `*.log`); one with `/` matches the whole relative
path.

### tport — `sync`

```
tport sync <local-folder> <url> [--direction up|down] [--delete] [--dry-run]
           [--size-only] [--exclude <pattern>]… [--allow-empty-source] [--max-items N]
```

Prints one line per action (`upload path`, `download path`, `mkdir path`,
`delete path`, `skip path (reason)`) and a summary; `--dry-run` stops there.
Runs the plan on its one connection: directories, transfers (setting
modification times), then deletions. Exit code 0 when everything applied,
1 if any action failed (the rest are still attempted).

### App

- **Session ▸ Sync Folders… (⇧⌘S)** and the remote pane's menu open a sheet
  for the local pane's folder and the active session's folder.
- The sheet: direction, "Delete files that aren't in the source", "Compare
  sizes only", **Compare** → the plan as a list (action, path, size or
  reason) with totals, then **Sync**.
- Sync creates directories and enqueues the transfers in the existing
  transfer queue as predetermined overwrites (progress, retries, pause,
  cancel all as usual), then performs deletions after a confirmation that
  states the count. Scanning, directory creation and deletion use a
  connection of their own, so the work doesn't depend on the tab staying open.
- `SyncViewModel` holds the state; the sheet is a thin view over it.

## Testing

- Unit: the comparison table above, tolerance cases, excludes, empty-source
  refusal, type conflicts, ordering of deletions; local scan against a temp
  tree; remote scan and the view model against a scripted client.
- Live: `tport sync` up then down against the docker servers (SFTP and FTP),
  a second run that transfers nothing, `--delete`, and `--dry-run` changing
  nothing.
