import SwiftUI
import TeleportKit

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var showingSSHConfigImport = false

    var body: some View {
        @Bindable var state = appState

        List(selection: $state.selectedConnectionID) {
            Section("Favorites") {
                if appState.connectionStore.connections.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No saved connections")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                        Button {
                            appState.editingConnection = nil
                            appState.showingConnectionEditor = true
                        } label: {
                            Label("Add Connection…", systemImage: "plus.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.vertical, 2)
                } else {
                    ForEach(appState.connectionStore.connections) { conn in
                        ConnectionRowView(connection: conn)
                            .tag(conn.id)
                            .contextMenu { contextMenu(for: conn) }
                    }
                    .onMove { from, to in
                        appState.connectionStore.move(from: from, to: to)
                    }
                    .onDelete { idx in
                        idx.map { appState.connectionStore.connections[$0] }
                           .forEach { appState.delete($0) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Teleport")
        // Double-click a favorite to connect — wired through the backing outline
        // view's native `doubleAction`, exactly like the file panes. A SwiftUI
        // tap gesture on the row (the previous approach) covers the whole row
        // rectangle but only fires on a double-tap, so it swallowed single
        // clicks in the empty trailing area and silently broke click-to-select
        // there. With no gesture attached, the List's own full-width selection
        // works again; the double-click connects the row the click just selected.
        .background(TableBridge { _ in
            guard let conn = appState.selectedConnection else { return }
            Task { await appState.openSession(for: conn) }
        })
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(isPresented: $showingSSHConfigImport) {
            SSHConfigImportSheet()
        }
        // Selecting a favorite just highlights it; connecting is an explicit
        // act (double-click, ⏎, or the context menu) so arrowing through the
        // list doesn't tear down and rebuild connections.
        .onKeyPress(.return) {
            guard let conn = appState.selectedConnection else { return .ignored }
            Task { await appState.openSession(for: conn) }
            return .handled
        }
    }

    @ViewBuilder
    private func contextMenu(for conn: Connection) -> some View {
        Button(appState.sessions(for: conn).isEmpty ? "Connect" : "Switch to Session") {
            Task { await appState.openSession(for: conn) }
        }
        Button("Open in New Tab") { Task { await appState.openNewSession(for: conn) } }
            .help("Open another session to this server alongside the ones already open")
        Divider()
        Button("Edit…") {
            appState.editingConnection     = conn
            appState.showingConnectionEditor = true
        }
        Button("Duplicate") { Task { appState.duplicate(conn) } }
        Divider()
        Button("Delete", role: .destructive) {
            appState.delete(conn)
        }
    }

    /// The selected favourite, when it isn't already the active session.
    private var connectableSelection: Connection? {
        guard let conn = appState.selectedConnection else { return nil }
        return appState.activeSession?.connection.id == conn.id ? nil : conn
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New Connection…") {
                    appState.editingConnection     = nil
                    appState.showingConnectionEditor = true
                }
                Button("Import from SSH Config…") { showingSSHConfigImport = true }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a connection")
            .accessibilityLabel("Add Connection")

            Spacer(minLength: 4)

            if let session = appState.activeSession {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.green)
                        .frame(width: 7, height: 7)
                    Text(session.connection.host)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await appState.disconnect() }
                } label: {
                    Image(systemName: "bolt.slash")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Disconnect")
                .accessibilityLabel("Disconnect")
            } else if let conn = connectableSelection {
                // Explicit, discoverable connect for the highlighted favourite
                // (selecting no longer auto-connects).
                Button("Connect") { Task { await appState.openSession(for: conn) } }
                    .controlSize(.small)
                    .help("Connect to \(conn.displayTitle) (⏎)")
            }
            if appState.activeSession != nil, let conn = connectableSelection {
                // With a session on screen, the highlighted favourite can
                // still be opened next to it.
                Button(appState.sessions(for: conn).isEmpty ? "Connect" : "Switch") {
                    Task { await appState.openSession(for: conn) }
                }
                .controlSize(.small)
                .help("Open \(conn.displayTitle) alongside the current session (⏎)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - ConnectionRowView

struct ConnectionRowView: View {
    let connection: Connection
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: connection.connectionProtocol.systemImage)
                .foregroundStyle(protocolColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                Text(connection.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Any open session to this favourite, not just the one on screen.
            let open = appState.sessions(for: connection)
            if open.contains(where: \.isConnecting) {
                ProgressView().controlSize(.small)
            } else if !open.isEmpty {
                Circle().fill(.green).frame(width: 7, height: 7)
                    .accessibilityLabel(open.count == 1 ? "Connected" : "\(open.count) sessions open")
            }
        }
        .padding(.vertical, 2)
    }

    private var protocolColor: Color {
        switch connection.connectionProtocol {
        case .ftp:  return .orange
        case .ftps: return .blue
        case .sftp: return .green
        }
    }
}

// MARK: - AppState connection helpers

extension AppState {
    func duplicate(_ conn: Connection) {
        var copy       = conn
        copy.id        = UUID()
        copy.name      = "\(conn.displayTitle) copy"
        let pw         = connectionStore.password(for: conn)
        try? connectionStore.add(copy, password: pw)
        // Carry the SSH-key sandbox bookmark over so the copy can read the key
        // without the user re-selecting it.
        try? BookmarkStore.shared.duplicate(
            name: BookmarkStore.sshKeyName(for: conn.id),
            as:   BookmarkStore.sshKeyName(for: copy.id)
        )
    }

    /// Delete a connection plus its keychain password (via the store) and its
    /// SSH-key bookmark, so nothing is orphaned. Any sessions open to it are
    /// closed.
    func delete(_ conn: Connection) {
        let open = sessions(for: conn).map(\.id)
        if !open.isEmpty {
            Task { for id in open { await closeSession(id) } }
        }
        connectionStore.delete(conn)
        try? BookmarkStore.shared.remove(name: BookmarkStore.sshKeyName(for: conn.id))
    }
}
