# Multiple sessions — design

Date: 2026-10-13
Status: approved to build ("spec plan build"); not separately reviewed

## Goal

Stay connected to several servers at once and switch between them, instead
of every new connection tearing down the current one.

Today `AppState.activeSession` is the only session: connecting to a second
favourite disconnects the first, discarding its location, history and
selection.

## Decision: session tabs inside the window

Considered:

1. **Tabs over the remote pane (chosen).** One window, one local pane, one
   transfer queue; the remote pane shows whichever session is active.
2. **A window (or native window tab) per session.** More "Mac-like" on paper,
   but every per-window piece of state — command routing through
   notifications, the host-key / passphrase / conflict sheets bound to
   singletons, the split-view autosave, the local pane — would have to be
   split from the shared pieces first. That is a restructuring of the app,
   not a feature, and can follow later if wanted.

Option 1 keeps every existing code path that asks for "the active session"
working unchanged, because that question still has exactly one answer.

## Behaviour

- **Connecting** to a favourite that has no open session opens one alongside
  the others and makes it active. Nothing is disconnected.
- **Connecting** to a favourite that already has a session switches to it —
  double-clicking a favourite is "take me there", not "log in again".
- **Open in New Tab** (favourite's context menu) always opens another
  session, for two locations on one server side by side.
- **Tab strip** above the remote pane, shown when two or more sessions are
  open (with one session the window looks exactly as it does today). Each
  tab: protocol icon, title, a spinner while connecting, a close button.
  Two sessions to the same favourite are titled "name" and "name (2)".
- **Closing** a session disconnects it and activates its right-hand
  neighbour, else the left; closing the last one returns to the
  "No Remote Connection" placeholder.
- **A failed connection** removes its tab and shows the error; the session
  that was active before stays active.
- **Session menu:** Next Session ⇧⌘], Previous Session ⇧⌘[, Close Session
  ⇧⌘W. The toolbar and sidebar "Disconnect" close the active session.
- **Sidebar:** a favourite shows a green dot while it has any session, a
  spinner while one is connecting.
- **Deleting a favourite** closes all of its sessions.
- Each session keeps its own location, history, selection, sort and filter
  while in the background, and its own keep-alive.
- **Transfers** are unaffected: queued transfers carry their own connection
  and continue after their session's tab is closed.
- Uploads from the local pane and drags between panes use the active
  session, i.e. the one on screen.

## Not doing

- Server-to-server transfers between two sessions.
- Restoring open sessions at launch.
- Per-session local panes or separate windows.
- A limit on the number of sessions.

## Design

`AppState` owns `sessions: [RemoteSession]` and `activeSessionID`;
`activeSession` becomes a computed property. All session lifecycle moves out
of `SidebarView.swift` into `AppState` proper, with the client factory
injected so it can be unit-tested with a scripted client:

```swift
init(connectionStore: ConnectionStore = ConnectionStore(),
     clientFactory: @escaping (Connection, String) -> RemoteClient = RemoteClientFactory.make(for:password:))
func openSession(for: Connection) async            // switch to existing, else open
func openNewSession(for: Connection) async         // always open another
func closeSession(_ id: RemoteSession.ID) async
func disconnect() async                            // close the active one
func activate(_ id: RemoteSession.ID)
func activateNextSession() / activatePreviousSession()   // wrap around
func title(for: RemoteSession) -> String
func sessions(for: Connection) -> [RemoteSession]
```

The remote pane's content is keyed by session id so view-local state (open
sheets, drop highlights) never leaks from one session to another.

## Testing

Unit tests on `AppState` with a scripted `RemoteClient`: open/switch/duplicate,
failed connect, close ordering, last close, wrap-around, delete favourite,
titles, and that a session connecting in the background doesn't steal focus
back when it fails. The tab strip and menu are thin views over that state.
