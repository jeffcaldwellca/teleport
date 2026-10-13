import Foundation
import TeleportKit
import SwiftUI

/// Root application state — single source of truth passed through the environment.
@Observable
@MainActor
final class AppState {

    var connectionStore: ConnectionStore
    var transferQueue: TransferQueueViewModel

    /// Which browser pane keyboard commands (refresh, navigate, toggle hidden)
    /// should target. Tracks the last pane that took focus or selection so that
    /// menu shortcuts act on one pane instead of broadcasting to both.
    enum FocusedPane { case local, remote }
    var focusedPane: FocusedPane = .local

    /// Folder the local pane is showing — where downloads started from the
    /// remote pane land. Kept in sync by `ContentView`.
    var localPanePath: String = FileManager.default.homeDirectoryForCurrentUser.path

    // MARK: Sessions

    /// Every open remote session, in tab order.
    private(set) var sessions: [RemoteSession] = []
    private(set) var activeSessionID: RemoteSession.ID?

    /// The session on screen in the remote pane (nil when none is open).
    var activeSession: RemoteSession? {
        sessions.first { $0.id == activeSessionID }
    }

    private let clientFactory: (Connection, String) -> RemoteClient
    let removeKeyBookmark: @MainActor (UUID) -> Void

    /// The open session with this id, if it is still open.
    func session(withID id: RemoteSession.ID?) -> RemoteSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    // Sidebar / sheet state
    var selectedConnectionID: Connection.ID? = nil
    var showingConnectionEditor = false
    var editingConnection: Connection? = nil   // non-nil → editing; nil → new

    var selectedConnection: Connection? {
        guard let id = selectedConnectionID else { return nil }
        return connectionStore.connections.first { $0.id == id }
    }

    // Alert
    var alertTitle   = ""
    var alertMessage = ""
    var showingAlert = false

    /// - Parameter clientFactory: builds the client for each browsing
    ///   session; tests substitute a scripted one.
    ///   - removeKeyBookmark: drops the stored SSH-key bookmark of a deleted
    ///     connection.
    init(
        connectionStore store: ConnectionStore = ConnectionStore(),
        removeKeyBookmark: @escaping @MainActor (UUID) -> Void = {
            try? BookmarkStore.shared.remove(name: BookmarkStore.sshKeyName(for: $0))
        },
        clientFactory: @escaping (Connection, String) -> RemoteClient = RemoteClientFactory.make(for:password:)
    ) {
        connectionStore = store
        self.removeKeyBookmark = removeKeyBookmark
        self.clientFactory = clientFactory
        transferQueue = TransferQueueViewModel(passwordProvider: { store.password(for: $0) })

        // Uploads refresh the session(s) of the server they went to — which
        // may well not be the tab on screen. (Downloads refresh the local
        // pane, from the pane itself.)
        NotificationCenter.default.addObserver(
            forName: .transferCompleted, object: nil, queue: .main
        ) { [weak self] note in
            guard note.userInfo?["direction"] as? String == "upload",
                  let connectionID = note.userInfo?["connectionID"] as? UUID else { return }
            MainActor.assumeIsolated {
                self?.sessions.filter { $0.connection.id == connectionID }.forEach { $0.scheduleRefresh() }
            }
        }
    }

    // MARK: Sync

    /// The Sync Folders sheet, when it is open.
    var syncModel: SyncViewModel?

    private static func syncExcludesKey(for connection: Connection) -> String {
        "sync.excludes.\(connection.id.uuidString)"
    }

    /// Open Sync Folders for the folders the two panes are showing.
    func beginSync() {
        guard let session = activeSession else { return }
        let model = SyncViewModel(
            connection: session.connection,
            localRoot: URL(fileURLWithPath: localPanePath),
            remoteRoot: session.browser.currentPath,
            queue: transferQueue,
            // What to skip tends to be the same every time for a given site.
            excludeText: UserDefaults.standard.string(forKey: Self.syncExcludesKey(for: session.connection)) ?? ""
        )
        // Folders created and files deleted don't pass through the queue, so
        // nothing else would tell the panes to look again.
        model.onApplied = { [weak session, weak model] in
            if let session, let model {
                UserDefaults.standard.set(model.excludeText, forKey: Self.syncExcludesKey(for: session.connection))
            }
            session?.scheduleRefresh()
            NotificationCenter.default.post(name: .localFilesChanged, object: nil)
        }
        syncModel = model
    }

    // MARK: Opening sessions

    /// "Take me to this server": switch to its session if it has one,
    /// otherwise open one alongside whatever else is connected.
    func openSession(for connection: Connection) async {
        // Already looking at it (possibly its second tab): stay put.
        let open = sessions(for: connection)
        if let existing = open.first(where: { $0.id == activeSessionID }) ?? open.first {
            activate(existing.id)
            return
        }
        await openNewSession(for: connection)
    }

    /// Always opens another session, even to a server that already has one
    /// — for two locations on the same server side by side.
    func openNewSession(for connection: Connection) async {
        let previouslyActive = activeSessionID
        let client = clientFactory(connection, connectionStore.password(for: connection))
        let session = RemoteSession(connection: connection, client: client)
        sessions.append(session)
        activeSessionID = session.id
        selectedConnectionID = connection.id   // reflect what we're connecting to
        focusedPane = .remote                   // make the just-opened pane the command target

        await session.connect()

        // Closed while it was still connecting: it's gone, and whatever the
        // attempt came to is nobody's business any more.
        guard sessions.contains(where: { $0.id == session.id }) else {
            await session.disconnect()
            return
        }
        guard let error = session.connectionError else { return }

        showError(title: "Connection Failed", message: error)
        sessions.removeAll { $0.id == session.id }
        // Only hand focus back if the failed tab is the one the user was
        // still looking at; if they've moved on, leave them where they are.
        if activeSessionID == session.id {
            let fallback = sessions.first { $0.id == previouslyActive } ?? sessions.last
            setActive(fallback?.id)
        }
    }

    // MARK: Switching

    func activate(_ id: RemoteSession.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        setActive(id)
        // The sidebar highlight follows a tab the user chose…
        selectedConnectionID = session.connection.id
    }

    func activateNextSession() { step(by: 1) }
    func activatePreviousSession() { step(by: -1) }

    private func step(by offset: Int) {
        guard sessions.count > 1,
              let index = sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }
        activate(sessions[(index + offset + sessions.count) % sessions.count].id)
    }

    /// …but not one they merely landed on because another tab closed or
    /// failed to open: the highlight stays on the favourite they last picked,
    /// ready to be reconnected.
    private func setActive(_ id: RemoteSession.ID?) {
        activeSessionID = id
        focusedPane = id == nil ? .local : .remote
    }

    // MARK: Closing

    /// Disconnect and remove a session. If it was the one on screen, its
    /// right-hand neighbour takes over, else the left.
    func closeSession(_ id: RemoteSession.ID) async {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: index)
        if activeSessionID == id {
            // After the removal the right-hand neighbour sits at `index`.
            let neighbour = index < sessions.count ? sessions[index] : sessions.last
            setActive(neighbour?.id)
        }
        // Leave selectedConnectionID intact so the favorite stays highlighted
        // and can be reconnected without first selecting a different row.
        await session.disconnect()
    }

    /// Close the session on screen.
    func disconnect() async {
        guard let id = activeSessionID else { return }
        await closeSession(id)
    }

    // MARK: Describing

    func sessions(for connection: Connection) -> [RemoteSession] {
        sessions.filter { $0.connection.id == connection.id }
    }

    /// Tab title: the favourite's name, numbered from the second session to
    /// the same favourite on ("web", "web (2)").
    func title(for session: RemoteSession) -> String {
        let siblings = sessions(for: session.connection)
        guard let position = siblings.firstIndex(where: { $0.id == session.id }), position > 0 else {
            return session.connection.displayTitle
        }
        return "\(session.connection.displayTitle) (\(position + 1))"
    }

    func showError(_ error: Error) {
        alertTitle   = "Error"
        alertMessage = error.localizedDescription
        showingAlert = true
    }

    func showError(title: String, message: String) {
        alertTitle   = title
        alertMessage = message
        showingAlert = true
    }
}

// MARK: - RemoteSession

/// Holds an active remote connection and its browser state.
@Observable
@MainActor
final class RemoteSession: Identifiable {
    let id = UUID()
    let connection: Connection
    let client: RemoteClient

    var browser: BrowserViewModel
    var isConnecting = false
    var connectionError: String? = nil

    private var keepAliveTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(connection: Connection, client: RemoteClient) {
        self.connection = connection
        self.client     = client
        self.browser    = BrowserViewModel(client: client, initialPath: connection.initialPath)
    }

    func connect() async {
        isConnecting = true
        connectionError = nil
        do {
            try await client.connect()
            await browser.loadDirectory(path: connection.initialPath)
            startKeepAlive()
        } catch {
            connectionError = error.localizedDescription
        }
        isConnecting = false
    }

    func disconnect() async {
        browser.close()
        refreshTask?.cancel()
        keepAliveTask?.cancel()
        keepAliveTask = nil
        await client.disconnect()
    }

    /// Re-list shortly after uploads land so new files appear without a
    /// manual refresh. Debounced: a batch of completions is one reload.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, !self.browser.isLoading else { return }
            await self.browser.refresh()
        }
    }

    /// Periodically ping the server so an idle session isn't dropped. Harmless
    /// if the connection is already gone (the next browse op reconnects).
    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { break }
                await self?.client.keepAlive()
            }
        }
    }
}
