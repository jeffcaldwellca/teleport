# Multiple Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep several remote sessions open at once in one window, switched with a tab strip over the remote pane.

**Architecture:** `AppState` holds a list of `RemoteSession`s and the id of the active one; `activeSession` becomes computed, so every existing consumer keeps working. Session lifecycle moves from an extension in `SidebarView.swift` into `AppState`, with the client factory injected for tests. Views are thin: a tab strip, a Session menu, and sidebar indicators.

**Tech Stack:** Swift 5.9, SwiftUI (macOS 14), Observation, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-13-multiple-sessions-design.md`

## Global Constraints

- With exactly one session open the window must look and behave as before (no tab strip).
- Connecting to a favourite that already has a session switches to it; nothing is ever disconnected implicitly.
- Closing a session activates the right-hand neighbour, else the left.
- Shortcuts: Next Session ⇧⌘], Previous Session ⇧⌘[, Close Session ⇧⌘W. Existing shortcuts unchanged.
- No `Co-Authored-By` trailers. New app files need `xcodegen generate`.

## Review Focus

1. **A connection that fails after the user has switched to another tab** — must not yank focus or clear the tab they are now on.
2. **Closing a session while it is still connecting** — its late success/failure must not resurrect it or show an alert for a tab that is gone.
3. **Two sessions to one favourite** — sidebar indicator, titles, and "delete favourite" must treat both.
4. **Closing the active session from the middle of the strip** — the neighbour rule, and focus stays on the remote pane.
5. **View state bleeding between sessions** (an open rename field or delete confirmation carried to another server).

1–4 are pinned by named tests in Task 1; 5 by keying the pane on the session id in Task 2 (no unit test possible; called out for on-screen review).

## File Structure

| File | Responsibility |
|---|---|
| `Teleport/ViewModels/AppState.swift` | Session list, active id, lifecycle, titles |
| `Teleport/Views/Sidebar/SidebarView.swift` | Loses the lifecycle extension; indicators; "Open in New Tab" |
| `Teleport/Views/Browser/SessionTabBar.swift` (new) | The tab strip |
| `Teleport/Views/ContentView.swift` | Hosts the strip; keys the remote pane by session |
| `Teleport/TeleportApp.swift` | Session menu + notifications |
| `TeleportTests/AppStateSessionTests.swift` (new) | Lifecycle tests |

---

### Task 1: Session list in AppState

**Files:** modify `AppState.swift`, `SidebarView.swift` (remove `openSession`/`disconnect`/`delete` session logic from the extension; keep `duplicate`); create `TeleportTests/AppStateSessionTests.swift`.

**Interfaces — Produces** (all `@MainActor` on `AppState`):

```swift
init(connectionStore: ConnectionStore = ConnectionStore(),
     clientFactory: @escaping (Connection, String) -> RemoteClient = RemoteClientFactory.make(for:password:))
private(set) var sessions: [RemoteSession]
private(set) var activeSessionID: RemoteSession.ID?
var activeSession: RemoteSession? { get }
func openSession(for connection: Connection) async
func openNewSession(for connection: Connection) async
func closeSession(_ id: RemoteSession.ID) async
func disconnect() async
func activate(_ id: RemoteSession.ID)
func activateNextSession(); func activatePreviousSession()
func title(for session: RemoteSession) -> String
func sessions(for connection: Connection) -> [RemoteSession]
func delete(_ conn: Connection)        // also closes that favourite's sessions
```

- [ ] Step 1 — failing tests with a `GatedClient` (connect can be held open, made to fail, counts connects/disconnects):
  `test_openingASecondFavourite_keepsTheFirstConnected`,
  `test_openingAFavouriteThatIsAlreadyOpen_switchesToIt_withoutReconnecting`,
  `test_openNewSession_opensAnotherSessionToTheSameFavourite_withNumberedTitles`,
  `test_failedConnection_removesItsTab_andLeavesThePreviousSessionActive`,
  `test_failureAfterTheUserSwitchedAway_doesNotStealFocus` (RF 1),
  `test_closingASessionThatIsStillConnecting_dropsItQuietly` (RF 2),
  `test_closingTheActiveSession_activatesTheRightHandNeighbour_elseTheLeft` (RF 4),
  `test_closingTheLastSession_returnsFocusToTheLocalPane`,
  `test_nextAndPrevious_wrapAround`,
  `test_deletingAFavourite_closesAllOfItsSessions` (RF 3),
  `test_closingASession_disconnectsItsClient`.
- [ ] Step 2 — run `-only-testing:TeleportTests/AppStateSessionTests`; expect compile failure (`sessions`, `openNewSession`, injected init missing).
- [ ] Step 3 — implement. `open(_:)` appends a session, activates it, sets `focusedPane = .remote`, awaits `connect()`; afterwards, if the session is no longer in `sessions` (closed meanwhile) do nothing; if it failed, remove it, show the alert, and only if it was still the active one fall back to the previously active session (or the last remaining, or nil → `focusedPane = .local`).
- [ ] Step 4 — run the class, then the whole app suite.
- [ ] Step 5 — commit "Keep several sessions open in AppState".

### Task 2: Tab strip, Session menu, sidebar

**Files:** create `SessionTabBar.swift`; modify `ContentView.swift`, `TeleportApp.swift`, `SidebarView.swift`, `MainToolbarContent.swift`.

**Interfaces — Consumes:** everything Task 1 produces.

- [ ] Step 1 — `SessionTabBar`: horizontal scroller of tabs (`ForEach(appState.sessions)`), each a button calling `activate`, with `connectionProtocol.systemImage`, `title(for:)`, `ProgressView` while `isConnecting`, and a close button calling `closeSession`; active tab tinted; accessibility labels "Session <title>" / "Close <title>".
- [ ] Step 2 — `ContentView`: `RemotePane` shows the strip above the pane when `appState.sessions.count > 1`, and applies `.id(session.id)` to the `BrowserPaneView` (RF 5).
- [ ] Step 3 — `TeleportApp`: `CommandMenu("Session")` posting `.sessionNext`, `.sessionPrevious`, `.sessionClose`; `ContentView` handles them via `appState`.
- [ ] Step 4 — `SidebarView`: indicator uses `sessions(for:)` (spinner if any is connecting, dot if any exists); context menu gains "Open in New Tab"; the bottom bar's Connect button appears when the selection is not the *active* session's favourite.
- [ ] Step 5 — `xcodegen generate`; build; full suites (package + app with live servers); commit "Add session tabs, a Session menu and sidebar indicators".

## Self-review

- Spec coverage: behaviour bullets 1–3, 5–7, 9 → Task 1 tests; tab strip, menu, sidebar → Task 2; transfers unaffected (no code change; existing queue tests).
- No placeholders; names consistent between tasks.
- Review Focus 1–4 have tests; 5 is structural and flagged for on-screen review.
