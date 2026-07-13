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

    // Currently-open remote session (nil when not connected)
    var activeSession: RemoteSession? = nil

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

    init() {
        let store = ConnectionStore()
        connectionStore = store
        transferQueue = TransferQueueViewModel(passwordProvider: { store.password(for: $0) })
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
        keepAliveTask?.cancel()
        keepAliveTask = nil
        await client.disconnect()
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
