# Folder Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-way folder sync (upload or download) that transfers only what differs, with a preview, in the app and as `tport sync`.

**Architecture:** A pure planner in TeleportKit (`FolderSync`) turns two scanned trees into a list of actions; scanners for a local folder and a `RemoteClient` feed it. `tport sync` executes a plan directly on its connection. The app's `SyncViewModel` executes one through the existing transfer queue. Nothing is changed before a plan exists.

**Tech Stack:** Swift 5.9, TeleportKit, swift-argument-parser, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-13-folder-sync-design.md`

## Global Constraints

- One-way only; no two-way merge.
- Tolerance: 2 s, or 60 s when the remote time has no seconds.
- Deletion off by default; an empty source with deletion on is refused unless `allowEmptySource`.
- A missing source folder is an error.
- Limit: 10,000 entries per side.
- `.DS_Store` always excluded; excluded paths are never transferred **or deleted**.
- Type conflicts (file vs directory) are skipped, never replaced.
- Local deletions go to the Trash; deletions run after transfers, deepest first.
- No `Co-Authored-By` trailers. New app files need `xcodegen generate`.

## Review Focus

1. **Server reporting times to the minute (FTP `LIST`)** — a second run must transfer nothing.
2. **Deletion with an empty or missing source** — refused / an error; nothing deleted.
3. **A file on one side and a folder of the same name on the other** — skipped and reported; neither is deleted, and nothing *inside* the folder is touched.
4. **Excluded directory** (`node_modules`) present only at the destination with deletion on — left alone, along with everything under it.
5. **A transfer that fails mid-sync in `tport`** — the rest still run, deletions still happen only for paths unaffected, exit code is 1.

Each has a named test below.

## File Structure

| File | Responsibility |
|---|---|
| `TeleportKit/Sources/TeleportKit/FolderSync.swift` | Entries, options, planner, scanners, exclude matching |
| `TeleportKit/Sources/tport/SyncCommand.swift` | `tport sync`: scan, print, execute |
| `Teleport/ViewModels/SyncViewModel.swift` | App-side state: compare, apply through the queue |
| `Teleport/Views/Sheets/SyncSheet.swift` | The sheet |
| `Teleport/ViewModels/TransferQueueViewModel.swift` | Batch enqueue with predetermined overwrite |

---

### Task 1: Planner

**Files:** Create `FolderSync.swift`; Test `TeleportKit/Tests/TeleportKitTests/FolderSyncPlanTests.swift`.

**Produces:** the types and `FolderSync.plan(local:remote:direction:options:)` and `FolderSync.matches(exclude:relativePath:)` from the spec.

- [ ] Step 1 — failing tests: `test_missingAtDestination_isTransferred`, `test_differentSize_isTransferred`, `test_sameSize_sourceNewerBeyondTolerance_isTransferred`, `test_sameSize_withinTolerance_isInSync`, `test_minutePrecisionRemoteTime_usesTheWiderTolerance` (RF 1), `test_sizeOnly_ignoresTimes`, `test_download_mirrorsTheRules`, `test_extraneous_isLeftAlone_unlessDeletionIsOn`, `test_deletions_areOrderedDeepestFirst_andAfterTransfers`, `test_emptySource_withDeletion_isRefused` (RF 2), `test_typeConflict_isSkipped_andNothingUnderItIsTouched` (RF 3), `test_excluded_isNeitherTransferredNorDeleted_includingDescendants` (RF 4), `test_missingDirectories_areCreated_parentsFirst`, `test_excludePatterns`.
- [ ] Step 2 — run `swift test --filter FolderSyncPlanTests`; expect compile failure.
- [ ] Step 3 — implement.
- [ ] Step 4 — run the filter, then `swift test`.
- [ ] Step 5 — commit "Add the folder sync planner".

### Task 2: Scanners

**Files:** modify `FolderSync.swift`; Test `FolderSyncScanTests.swift` (TeleportKitTests; a `TreeClient` stub listing an in-memory tree).

- [ ] Step 1 — failing tests: `test_scanLocal_listsFilesAndFoldersRelativeToTheRoot`, `test_scanLocal_skipsSymlinksAndExcludedNames`, `test_scanLocal_missingRoot_throws` (RF 2), `test_scanLocal_overTheLimit_throws`, `test_scanRemote_walksTheTree_skippingSymlinksAndExcluded`, `test_scanRemote_marksTimesWithoutSeconds`, `test_scanRemote_overTheLimit_throws`.
- [ ] Step 2 — run; expect compile failure.
- [ ] Step 3 — implement `scanLocal` / `scanRemote`.
- [ ] Step 4 — `swift test`; commit "Scan local and remote trees for sync".

### Task 3: `tport sync`

**Files:** Create `SyncCommand.swift`; modify `Tport.swift`, `README.md`; Tests in `TeleportTests/CLIIntegrationTests.swift`.

- [ ] Step 1 — failing live tests: `test_sync_uploadsOnlyWhatChanged_andASecondRunDoesNothing` (SFTP and FTP — RF 1 on the FTP server), `test_sync_dryRun_changesNothing`, `test_sync_delete_removesExtraneousRemoteFiles`, `test_sync_down_bringsTheLocalFolderUpToDate`, `test_sync_emptySourceWithDelete_isRefused` (RF 2), `test_sync_continuesPastAFailedFile_andExitsNonZero` (RF 5; an unreadable local file).
- [ ] Step 2 — run; expect "unknown subcommand".
- [ ] Step 3 — implement the command and executor; register it; README section.
- [ ] Step 4 — rebuild `tport`; run CLI tests; commit "Add tport sync".

### Task 4: App

**Files:** Create `SyncViewModel.swift`, `SyncSheet.swift`; modify `TransferQueueViewModel.swift`, `TeleportApp.swift`, `ContentView.swift`, `BrowserPaneView.swift`; Test `TeleportTests/SyncViewModelTests.swift`.

**Produces:**

```swift
// TransferQueueViewModel
func enqueueBatch(connection:, direction:, items: [(local: URL, remote: String)], conflictBehavior: ConflictResolution?)
@Observable @MainActor final class SyncViewModel {
    enum Phase: Equatable { case idle, comparing, ready, applying, done(String), failed(String) }
    init(connection: Connection, localRoot: URL, remoteRoot: String, queue: TransferQueueViewModel,
         trash: @escaping (URL) throws -> Void = { try LocalFileService.shared.delete(at: $0) })
    var direction: SyncDirection; var deleteExtraneous: Bool; var sizeOnly: Bool
    private(set) var phase: Phase; private(set) var plan: SyncPlan?
    func compare() async; func apply() async
}
```

- [ ] Step 1 — failing tests with a `TreeClient` that records calls: `test_compare_producesAPlan_withoutChangingAnything`, `test_apply_upload_createsFolders_enqueuesTransfersAsOverwrites`, `test_apply_withDeletion_deletesExtraneousRemoteFiles`, `test_apply_download_trashesExtraneousLocalFiles`, `test_changingAnOption_discardsTheStalePlan`, `test_compare_failure_isReported`.
- [ ] Step 2 — run; expect compile failure.
- [ ] Step 3 — implement the view model, sheet, menu item (Session ▸ Sync Folders… ⇧⌘S, disabled without a session) and the remote pane's menu entry; `xcodegen generate`.
- [ ] Step 4 — full suites with live servers; commit "Add Sync Folders to the app".

## Self-review

- Spec coverage: comparison table + safety → Task 1; scanning rules → Task 2; CLI → Task 3; app → Task 4.
- Review Focus 1–5 → Task 1 (1–4) and Task 3 (1, 2, 5).
- Names consistent: `SyncEntry`, `SyncAction`, `SyncPlan`, `FolderSync.plan/scanLocal/scanRemote`, `enqueueBatch(…conflictBehavior:)`.
