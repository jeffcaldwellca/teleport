import SwiftUI

struct MainToolbarContent: ToolbarContent {
    @Environment(AppState.self) private var appState

    var body: some ToolbarContent {
        // ── Left: New Connection ───────────────────────────────────
        ToolbarItemGroup(placement: .navigation) {
            Button {
                appState.editingConnection = nil
                appState.showingConnectionEditor = true
            } label: {
                Label("New Connection", systemImage: "plus")
            }
            .help("New Connection (⌘N)")
        }

        // ── Right: session controls ────────────────────────────────
        ToolbarItemGroup(placement: .primaryAction) {
            if let session = appState.activeSession {
                Button {
                    Task { await appState.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
                .help("Disconnect from \(session.connection.host)")
            }

            Button {
                appState.transferQueue.toggleVisible()
            } label: {
                Label(
                    "Transfers",
                    systemImage: appState.transferQueue.hasActiveTasks
                        ? "arrow.up.arrow.down.circle.fill"
                        : "arrow.up.arrow.down.circle"
                )
            }
            .help(appState.transferQueue.isVisible ? "Hide Transfers" : "Show Transfers")
        }
    }
}
