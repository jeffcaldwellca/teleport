import SwiftUI
import TeleportKit

struct ContentView: View {
    @Environment(AppState.self) private var appState

    @State private var localBrowser  = BrowserViewModel(localPath: ContentView.initialLocalPath())

    /// Under App Sandbox, `homeDirectoryForCurrentUser` returns the container
    /// (which is empty), so default to Downloads — covered by our entitlement.
    /// The user can change this from Settings; bookmarks persist the choice.
    private static func initialLocalPath() -> String {
        if let bookmarked = try? BookmarkStore.shared.resolve(name: BookmarkStore.localRootName) {
            return bookmarked.path
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                // ── Two-pane browser ──────────────────────────────
                HSplitView {
                    BrowserPaneView(
                        vm: localBrowser,
                        side: .local,
                        paneTitle: "Local",
                        systemImage: "laptopcomputer",
                        remoteSession: nil
                    )
                    .frame(minWidth: 280)

                    if let session = appState.activeSession {
                        BrowserPaneView(
                            vm: session.browser,
                            side: .remote,
                            paneTitle: session.connection.displayTitle,
                            systemImage: session.connection.connectionProtocol.systemImage,
                            remoteSession: session
                        )
                        .frame(minWidth: 280)
                    } else {
                        NoConnectionView()
                            .frame(minWidth: 280)
                    }
                }

                Divider()

                // ── Transfer queue ────────────────────────────────
                if appState.transferQueue.isVisible {
                    TransferQueueView()
                        .frame(minHeight: 80, maxHeight: 220)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar { MainToolbarContent() }
        .alert(appState.alertTitle, isPresented: $state.showingAlert) {
            Button("OK") {}
        } message: {
            Text(appState.alertMessage)
        }
        .sheet(isPresented: $state.showingConnectionEditor) {
            ConnectionEditorView(existing: appState.editingConnection)
        }
        .sheet(item: Binding(
            get: { appState.transferQueue.pendingConflict },
            // If the sheet is dismissed by any path other than its buttons,
            // treat it as "Skip" so the awaiting transfer continuation resolves
            // instead of leaving the queue stuck. (No-op once already resolved.)
            set: { if $0 == nil { appState.transferQueue.resolveConflict(.skip, applyToAll: false) } }
        )) { conflict in
            ConflictResolutionSheet(conflict: conflict)
        }
        .sheet(item: Binding(
            get: { HostKeyConfirmation.shared.pending },
            // Dismissal without an explicit choice is the safe default: reject.
            set: { if $0 == nil { HostKeyConfirmation.shared.reject() } }
        )) { request in
            HostKeyConfirmationSheet(request: request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newConnection)) { _ in
            appState.editingConnection = nil
            appState.showingConnectionEditor = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTransferQueue)) { _ in
            appState.transferQueue.toggleVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: .localRootChanged)) { note in
            // Apply a Settings change to the open pane immediately instead of
            // requiring a relaunch.
            guard let path = note.userInfo?["path"] as? String else { return }
            Task { await localBrowser.loadDirectory(path: path) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchPane)) { _ in
            // Only meaningful when a remote pane exists.
            guard appState.activeSession != nil else { appState.focusedPane = .local; return }
            appState.focusedPane = (appState.focusedPane == .local) ? .remote : .local
        }
        .task {
            // Saves of remotely-edited files upload through the queue, always
            // overwriting their own remote file (no conflict dialog per save).
            RemoteEditManager.shared.enqueueUpload = { connection, url, remotePath in
                appState.transferQueue.enqueue(
                    connection: connection,
                    direction: .upload,
                    localURL: url,
                    remotePath: remotePath,
                    conflictBehavior: .overwrite
                ) != nil
            }
            // Seed local browser
            await localBrowser.refresh()
        }
    }
}

// MARK: - No Connection Placeholder

struct NoConnectionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Inert pane header so this pane visually matches the Local pane.
            HStack(spacing: 6) {
                Image(systemName: "network.slash")
                    .foregroundStyle(.tertiary)
                Text("Remote")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.background.secondary)

            Divider()

            VStack(spacing: 14) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 44, weight: .ultraLight))
                    .foregroundStyle(.tertiary)

                VStack(spacing: 4) {
                    Text("No Remote Connection")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Text("Double-click a favorite in the sidebar,\nor add a new connection.")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }

                Button("New Connection…") {
                    appState.editingConnection = nil
                    appState.showingConnectionEditor = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Bindable private var prefs = Preferences.shared
    @State private var localRootDisplay: String = SettingsView.currentLocalRoot()
    @State private var trustedHosts: [SSHHostKeyStore.TrustedHost] = []

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gear") }
            transfers
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
            security
                .tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(width: 480, height: 320)
    }

    private var general: some View {
        Form {
            Section("Local pane root") {
                HStack {
                    Text(localRootDisplay)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseLocalRoot() }
                }
                Text("The local pane opens in this folder by default. Saved as a security-scoped bookmark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Browser") {
                Toggle("Show hidden files by default", isOn: $prefs.showHiddenByDefault)
            }
        }
        .formStyle(.grouped)
    }

    private var transfers: some View {
        Form {
            Section("Concurrency") {
                Stepper("Max concurrent transfers: \(prefs.maxConcurrentTransfers)",
                        value: $prefs.maxConcurrentTransfers, in: 1...8)
            }
            Section("Defaults") {
                Picker("Download destination", selection: $prefs.downloadDestination) {
                    ForEach(Preferences.DownloadDestinationChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Picker("On conflict", selection: $prefs.defaultConflict) {
                    ForEach(Preferences.DefaultConflict.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var security: some View {
        Form {
            Section("Trusted SSH host keys") {
                if trustedHosts.isEmpty {
                    Text("No host keys trusted yet. The first time you connect to an SSH server, you'll be asked to verify its fingerprint.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(trustedHosts) { host in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.port == 22 ? host.host : "\(host.host):\(host.port)")
                                    .font(.callout)
                                Text(SSHKeyFingerprint.display(host.fingerprint))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Forget") { forgetHost(host) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                    Button("Forget All…") { forgetAllHosts() }
                        .controlSize(.small)
                        .foregroundStyle(.red)
                }
                Text("Forgetting a key makes the next connection re-prompt to confirm the server's fingerprint — useful after a legitimate server-key change, or to revoke trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await reloadTrustedHosts() }
    }

    private func reloadTrustedHosts() async {
        trustedHosts = await SSHHostKeyStore.shared.trustedHosts()
    }

    private func forgetHost(_ host: SSHHostKeyStore.TrustedHost) {
        Task {
            try? await SSHHostKeyStore.shared.forget(id: host.id)
            await reloadTrustedHosts()
        }
    }

    private func forgetAllHosts() {
        Task {
            try? await SSHHostKeyStore.shared.forgetAll()
            await reloadTrustedHosts()
        }
    }

    // MARK: - Actions

    private func chooseLocalRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories    = true
        panel.canChooseFiles          = false
        panel.allowsMultipleSelection = false
        panel.prompt                  = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try BookmarkStore.shared.save(url, name: BookmarkStore.localRootName)
                localRootDisplay = url.path
                NotificationCenter.default.post(
                    name: .localRootChanged, object: nil, userInfo: ["path": url.path]
                )
            } catch {
                NSLog("Failed to save local root bookmark: \(error)")
            }
        }
    }

    private static func currentLocalRoot() -> String {
        if let url = try? BookmarkStore.shared.resolve(name: BookmarkStore.localRootName) {
            return url.path
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }
}

// MARK: - Conflict Resolution Sheet

struct ConflictResolutionSheet: View {
    let conflict: ConflictInfo
    @Environment(AppState.self) private var appState
    @State private var applyToAll = false

    private var queue: TransferQueueViewModel { appState.transferQueue }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: conflict.isDownload ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(conflict.isDownload ? .blue : .green)

            VStack(spacing: 6) {
                Text("File Already Exists")
                    .font(.headline)
                Text("\"\(conflict.fileName)\" already exists at the \(conflict.isDownload ? "download destination" : "upload location").")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // Show modification dates if available
                if let local = conflict.localModifiedDate, let remote = conflict.remoteModifiedDate {
                    HStack(spacing: 16) {
                        dateLabel(label: "Local", date: local,  isNewer: local > remote)
                        dateLabel(label: "Remote", date: remote, isNewer: remote > local)
                    }
                    .font(.caption)
                    .padding(.top, 4)
                }
            }

            VStack(spacing: 8) {
                // "Overwrite if Newer" is the prominent default — pressing Return
                // can't destroy a file outright. Plain "Overwrite" is demoted to a
                // deliberate, non-default choice.
                Button { resolve(.overwriteIfNewer) } label: {
                    Text("Overwrite if Newer").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help(conflict.isDownload
                      ? "Replace local file only if remote version is newer"
                      : "Replace remote file only if local version is newer")

                Button { resolve(.overwrite) } label: {
                    Text("Overwrite").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button { resolve(.autoRename) } label: {
                    Text("Auto-Rename").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .cancel) { resolve(.skip) } label: {
                    Text("Skip").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }

            Toggle("Apply to all remaining conflicts", isOn: $applyToAll)
                .toggleStyle(.checkbox)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 360)
    }

    private func resolve(_ resolution: ConflictResolution) {
        queue.resolveConflict(resolution, applyToAll: applyToAll)
    }

    @ViewBuilder
    private func dateLabel(label: String, date: Date, isNewer: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(date, style: .date)
                .foregroundStyle(isNewer ? .primary : .secondary)
            Text(date, style: .time)
                .foregroundStyle(isNewer ? .primary : .secondary)
            if isNewer {
                Text("NEWER")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
