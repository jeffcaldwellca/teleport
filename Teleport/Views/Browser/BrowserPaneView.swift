import Quartz
import TeleportKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserPaneView: View {
    @Bindable var vm: BrowserViewModel
    let side: AppState.FocusedPane
    let paneTitle: String
    let systemImage: String
    let remoteSession: RemoteSession?

    @Environment(AppState.self) private var appState
    @State private var showingNewFolder = false
    @State private var autoRefreshTask: Task<Void, Never>?

    /// This pane is the target for keyboard commands (refresh, navigate, …).
    private var isActive: Bool { appState.focusedPane == side }

    /// Refresh shortly after transfers land so new files appear without a
    /// manual refresh. Debounced: a batch of completions triggers one reload.
    private func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, !vm.isLoading else { return }
            await vm.refresh()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Pane header ───────────────────────────────────────
            paneHeader

            Divider()

            // ── Breadcrumb ────────────────────────────────────────
            BreadcrumbView(path: vm.currentPath) { segment in
                Task { await vm.navigate(to: segment) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            // ── File list ─────────────────────────────────────────
            if let err = vm.loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(err).font(.callout).multilineTextAlignment(.center)
                    Button("Retry") { Task { await vm.retry() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The list stays mounted across reloads — a spinner overlays it
                // rather than replacing it, so navigating/refreshing doesn't blank
                // the pane. A full-screen spinner shows only before the first load.
                FileListView(vm: vm, side: side, remoteSession: remoteSession)
                    .overlay {
                        if vm.hasLoaded && vm.displayedItems.isEmpty {
                            emptyStateOverlay.allowsHitTesting(false)
                        } else if !vm.hasLoaded {
                            ProgressView("Loading…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.background)
                        }
                    }
            }
        }
        .sheet(isPresented: $showingNewFolder) {
            NewFolderSheet { name in
                Task {
                    do { try await vm.createDirectory(named: name) }
                    catch { appState.showError(error) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserRefresh)) { _ in
            guard isActive else { return }
            Task { await vm.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserGoUp)) { _ in
            guard isActive else { return }
            Task { await vm.goUp() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserGoBack)) { _ in
            guard isActive else { return }
            Task { await vm.goBack() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserGoForward)) { _ in
            guard isActive else { return }
            Task { await vm.goForward() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserToggleHidden)) { _ in
            guard isActive else { return }
            vm.showHidden.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transferCompleted)) { note in
            // Downloads land in the local pane, uploads in the remote pane.
            let direction = note.userInfo?["direction"] as? String
            let relevant = vm.isLocal ? direction == "download" : direction == "upload"
            if relevant { scheduleAutoRefresh() }
        }
    }

    // MARK: Pane Header

    private var hasNonDefaultViewSettings: Bool {
        vm.showHidden || vm.sortKey != .name || !vm.sortAscending
    }

    private var paneHeader: some View {
        HStack(spacing: 6) {
            // Pane identity — accent-tinted when this pane is the command target.
            Image(systemName: systemImage)
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(paneTitle)
                .font(.callout.weight(.medium))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

            Spacer(minLength: 8)

            // Inline filter field — shrinks gracefully on narrow panes.
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .imageScale(.small)
                TextField("Filter", text: $vm.filterText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !vm.filterText.isEmpty {
                    Button { vm.filterText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 80, maxWidth: 180)

            // Nav cluster: back / forward / up live together because they're peers.
            HStack(spacing: 2) {
                Button { Task { await vm.goBack() } } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(vm.history.isEmpty)
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back")

                Button { Task { await vm.goForward() } } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(vm.forwardStack.isEmpty)
                .buttonStyle(.plain)
                .help("Forward")
                .accessibilityLabel("Forward")

                Button { Task { await vm.goUp() } } label: {
                    Image(systemName: "arrow.up")
                }
                .disabled(vm.currentPath == "/" || vm.currentPath.isEmpty)
                .buttonStyle(.plain)
                .help("Parent folder")
                .accessibilityLabel("Parent folder")
            }

            // Refresh — swaps to a spinner while loading.
            Button { Task { await vm.refresh() } } label: {
                if vm.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(vm.isLoading)
            .buttonStyle(.plain)
            .help(vm.isLoading ? "Loading…" : "Refresh")
            .accessibilityLabel("Refresh")

            // Overflow menu: pane-level configuration + folder creation.
            Menu {
                sortMenu
                Divider()
                Toggle("Show Hidden Files", isOn: $vm.showHidden)
                Divider()
                Button {
                    showingNewFolder = true
                } label: {
                    Label("New Folder…", systemImage: "folder.badge.plus")
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "ellipsis.circle")
                    if hasNonDefaultViewSettings {
                        Circle()
                            .fill(.tint)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -1)
                    }
                }
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("View Options")
            .accessibilityLabel("View options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // Active pane: faint accent wash + top accent edge. Inactive: plain.
        .background(isActive ? AnyShapeStyle(Color.accentColor.opacity(0.10))
                             : AnyShapeStyle(.background.secondary))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.tint)
                .frame(height: 2)
                .opacity(isActive ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: vm.filterText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            if vm.filterText.isEmpty {
                Text("Empty Folder")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No matches for \u{201C}\(vm.filterText)\u{201D}")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Clear the filter to see all items.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu("Sort by \(vm.sortKey.label)") {
            ForEach(SortKey.allCases, id: \.self) { key in
                Button {
                    vm.setSort(key)
                } label: {
                    if vm.sortKey == key {
                        Label(key.label, systemImage: vm.sortAscending ? "chevron.up" : "chevron.down")
                    } else {
                        // Use the same Label structure with a transparent
                        // checkmark so column alignment stays consistent.
                        Text(key.label)
                    }
                }
            }
        }
    }
}

// MARK: - NewFolderSheet

/// Replaces the old `.alert` text field: the Create button can be disabled when
/// the name is blank, giving clear feedback instead of silently doing nothing.
struct NewFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    let onCreate: (String) -> Void

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Folder").font(.headline)

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed)
        dismiss()
    }
}

// MARK: - FileListView

struct FileListView: View {
    @Bindable var vm: BrowserViewModel
    let side: AppState.FocusedPane
    let remoteSession: RemoteSession?

    @Environment(AppState.self) private var appState
    @State private var showingDeleteConfirm = false
    @State private var itemsToDelete: [FileItem] = []
    @State private var showingPermissions = false
    @State private var permissionsItem: FileItem? = nil
    @State private var isDropTargeted = false
    /// Frame (in the Table's coordinate space) of the folder row a drag is
    /// hovering, so it can be highlighted as the drop target.
    @State private var dropFolderFrame: CGRect? = nil
    @State private var tableHandle = TableHandle()
    @FocusState private var listFocused: Bool

    /// Both panes take local file URLs and the internal remote-item payload;
    /// `dropOperation` decides per drag what (if anything) a drop would do.
    private let acceptedDropTypes: [UTType] = [.teleportRemoteItem, .fileURL]

    /// Read in `body` so the pane re-renders live when Settings changes it.
    private var textSize: Preferences.FileListTextSize { Preferences.shared.fileListTextSize }

    /// Bridges the Table's clickable column headers to the view model's sort
    /// state. Not stored anywhere — derived from the VM on read and pushed back
    /// on write — so it can't drift out of sync or loop with `didSet`.
    private var sortOrder: Binding<[KeyPathComparator<FileItem>]> {
        Binding(
            get: {
                let order: SortOrder = vm.sortAscending ? .forward : .reverse
                switch vm.sortKey {
                case .date: return [KeyPathComparator(\FileItem.modifiedDate, order: order)]
                case .size: return [KeyPathComparator(\FileItem.size, order: order)]
                default:    return [KeyPathComparator(\FileItem.name, order: order)]
                }
            },
            set: { newValue in
                guard let cmp = newValue.first else { return }
                let ascending = cmp.order == .forward
                let key: SortKey
                if cmp.keyPath == \FileItem.modifiedDate { key = .date }
                else if cmp.keyPath == \FileItem.size     { key = .size }
                else                                       { key = .name }
                vm.applySort(key: key, ascending: ascending)
            }
        )
    }

    var body: some View {
        Table(of: FileItem.self, selection: $vm.selectedItems, sortOrder: sortOrder) {
            TableColumn("Name", sortUsing: KeyPathComparator(\FileItem.name)) { item in
                // AppState goes in explicitly — a Table cell is hosted on its own
                // and can't rely on inheriting the environment. See FileNameCell.
                FileNameCell(item: item, vm: vm, appState: appState, textSize: textSize)
            }
            .width(min: 180, ideal: 340)

            TableColumn("Date Modified", sortUsing: KeyPathComparator(\FileItem.modifiedDate)) { item in
                Text(item.modifiedDate.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                    .font(.system(size: textSize.pointSize))
                    .foregroundStyle(item.modifiedDate == nil ? .tertiary : .secondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 150)

            TableColumn("Size", sortUsing: KeyPathComparator(\FileItem.size)) { item in
                Text(item.isDirectory ? "—" : item.displaySize)
                    .font(.system(size: textSize.pointSize).monospacedDigit())
                    .foregroundStyle(item.isDirectory ? .tertiary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 96)
        } rows: {
            ForEach(vm.displayedItems) { item in
                // Drag lives on the row, not the cell, so the framework can tell
                // a click (select) from a drag.
                //
                // Drops are split by origin. Drags from the *other* pane or
                // Finder are handled pane-wide by `PaneDropDelegate`, which
                // resolves the hovered folder row itself. Drags that start in
                // this same table never reach the pane-level drop handler, so
                // folder rows carry a row-level `dropDestination` for that one
                // payload only. It has to stay that narrow: once a row claims a
                // payload type the table rejects it everywhere else (file rows,
                // empty space), which would kill the pane-wide fallback.
                if vm.isLocal, item.isDropTargetFolder {
                    // Local folder: dropping local items on it moves/copies them inside.
                    TableRow(item)
                        .draggable(URL(fileURLWithPath: item.path))
                        .dropDestination(for: LocalFileDrop.self) { drops in
                            moveOrCopyLocal(drops.map(\.url), into: item)
                        }
                        .contextMenu { contextMenu(for: item) }
                } else if vm.isLocal {
                    // Local file → real file URL (drag to remote pane / Finder).
                    TableRow(item)
                        .draggable(URL(fileURLWithPath: item.path))
                        .contextMenu { contextMenu(for: item) }
                } else if let session = remoteSession, !item.isDirectory,
                          let safeName = RemotePath.sanitizedFilename(item.name) {
                    // Remote file → in-app ref (drop on local pane, goes through
                    // the queue) + download-on-drop promise (drag to Finder).
                    TableRow(item)
                        .draggable(RemoteFileDrag(client: session.client,
                                                  connection: session.connection,
                                                  queue: appState.transferQueue,
                                                  remotePath: item.path,
                                                  fileName: safeName))
                        .contextMenu { contextMenu(for: item) }
                } else if let session = remoteSession, item.isDirectory, !item.isSymlink,
                          let safeName = RemotePath.sanitizedFilename(item.name) {
                    // Remote folder → in-app ref (recursive queue download on
                    // the local pane) + directory promise for Finder drops.
                    // Dropping remote items on it moves them into the folder.
                    TableRow(item)
                        .draggable(RemoteFolderDrag(client: session.client,
                                                    connection: session.connection,
                                                    queue: appState.transferQueue,
                                                    remotePath: item.path,
                                                    folderName: safeName))
                        .dropDestination(for: RemoteFileRef.self) { refs in
                            moveRemote(refs, into: item)
                        }
                        .contextMenu { contextMenu(for: item) }
                } else {
                    TableRow(item)
                        .contextMenu { contextMenu(for: item) }
                }
            }
        }
        .focused($listFocused)
        // Make this the command target when it takes focus or gains a selection,
        // so menu shortcuts (⌘R, ⌘↑, …) act on one pane instead of both.
        .onChange(of: listFocused) { _, focused in
            if focused { appState.focusedPane = side }
        }
        .onChange(of: vm.selectedItems) { _, selection in
            if !selection.isEmpty { appState.focusedPane = side }
        }
        // Move real keyboard focus here when this pane becomes the active one
        // (e.g. via the Switch Pane command), and give it up when the other pane
        // takes over. Dropping focus has to be explicit: the panes are hosted
        // separately (see PersistentHSplitView), so they sit in different SwiftUI
        // focus scopes and one taking focus no longer unsets the other.
        .onChange(of: appState.focusedPane) { _, pane in
            listFocused = (pane == side)
        }
        // Double-click to open/download. Implemented via the backing NSTableView's
        // native doubleAction (not a SwiftUI gesture, which would suppress
        // single-click selection). Purely additive: if the table can't be found,
        // selection + Return + the context menu still work.
        .background(TableBridge(handle: tableHandle) { row in
            guard row >= 0, row < vm.displayedItems.count else { return }
            activate(vm.displayedItems[row])
        })
        .overlay(dropHighlight)
        .onDrop(of: acceptedDropTypes, delegate: PaneDropDelegate(
            types: acceptedDropTypes,
            folderAt: { location in dropFolder(at: location) },
            canDrop: { info, folder in canDrop(info, into: folder) },
            hover: { targeted, frame in
                if isDropTargeted != targeted { isDropTargeted = targeted }
                if dropFolderFrame != frame { dropFolderFrame = frame }
            },
            perform: { providers, folder in performDrop(providers, into: folder) }
        ))
        .onKeyPress(.return) {
            guard let item = vm.selectedFileItems.first else { return .ignored }
            activate(item)
            return .handled
        }
        .onKeyPress(.delete) {
            deleteSelected()
            return .handled
        }
        .confirmationDialog(
            "Delete \(itemsToDelete.count) item\(itemsToDelete.count == 1 ? "" : "s")?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    do { try await vm.delete(items: itemsToDelete) }
                    catch { appState.showError(error) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(itemsToDelete.contains(where: \.isDirectory)
                 ? "Folders are deleted together with everything inside them. This action cannot be undone."
                 : "This action cannot be undone.")
        }
        .sheet(item: $permissionsItem) { item in
            if let session = remoteSession {
                PermissionsEditorSheet(item: item, session: session)
            }
        }
    }

    /// Hovering a folder row outlines that row; anywhere else in the pane
    /// outlines the whole list (the drop lands in the current directory).
    @ViewBuilder
    private var dropHighlight: some View {
        if let frame = dropFolderFrame {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.12).clipShape(RoundedRectangle(cornerRadius: 5)))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .clipped()
                .allowsHitTesting(false)
        } else if isDropTargeted {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .background(Color.accentColor.opacity(0.06).clipShape(RoundedRectangle(cornerRadius: 6)))
                .padding(4)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: Context Menu

    /// Routes to a multi-item menu when right-clicking inside a multi-selection,
    /// otherwise the full single-item menu.
    @ViewBuilder
    private func contextMenu(for item: FileItem) -> some View {
        let selection = vm.selectedFileItems
        if selection.count > 1, vm.selectedItems.contains(item.id) {
            multiContextMenu(for: selection)
        } else {
            singleContextMenu(for: item)
        }
    }

    @ViewBuilder
    private func multiContextMenu(for items: [FileItem]) -> some View {
        if vm.isLocal {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) })
            }
            Divider()
        } else if remoteSession != nil {
            let transferable = items.filter { !$0.isSymlink }
            Button("Download \(transferable.count) Item\(transferable.count == 1 ? "" : "s")") {
                downloadMultiple(transferable)
            }
            .disabled(transferable.isEmpty)
            Divider()
        }
        Button("Delete \(items.count) Items", role: .destructive) {
            itemsToDelete = items
            showingDeleteConfirm = true
        }
    }

    @ViewBuilder
    private func singleContextMenu(for item: FileItem) -> some View {
        if item.isDirectory {
            Button("Open") { Task { await vm.navigate(to: item.path) } }
            if !vm.isLocal, !item.isSymlink {
                Button("Download Folder") { downloadMultiple([item]) }
            }
        } else {
            if vm.isLocal {
                Button("Open") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
                }
                Button("Quick Look") {
                    QuickLookCoordinator.shared.preview(url: URL(fileURLWithPath: item.path))
                }
            } else {
                Button("Download") { downloadItem(item) }
                Button("Quick Look") { quickLookRemote(item) }
                    .help("Downloads a temporary copy and opens Quick Look")
                Button("Edit…") { editRemote(item) }
                    .help("Downloads a copy, opens it in the default app, and uploads automatically when you save")
            }
        }

        Divider()

        if !vm.isLocal, let session = remoteSession {
            Button("Upload Here…") { uploadToRemote(session: session) }
            Divider()
        }

        Button("Rename…") {
            vm.selectedItems = [item.id]
            vm.renamingItem  = item
            vm.renameText    = item.name
        }

        if !item.isDirectory || vm.isLocal {
            Button("Duplicate") { duplicateItem(item) }
                .help(vm.isLocal ? "Copy next to the original"
                                 : "Copies via a temporary download (no server-side copy in FTP/SFTP)")
        }

        Button("Delete", role: .destructive) {
            itemsToDelete = [item]
            showingDeleteConfirm = true
        }

        if vm.isLocal {
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
        } else if remoteSession != nil {
            Divider()
            Button("Permissions & Ownership…") {
                permissionsItem = item
            }
        }
    }

    // MARK: Activation

    private func activate(_ item: FileItem) {
        if item.isDirectory {
            Task { await vm.navigate(to: item.path) }
        } else if vm.isLocal {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        } else if item.isSymlink {
            // Listings report symlinks with lstat semantics, so a link to a
            // directory looks like a file. Probe before deciding: navigable →
            // treat as folder, otherwise download it like a file.
            Task {
                if await vm.probeDirectory(item.path) {
                    await vm.navigate(to: item.path)
                } else {
                    downloadItem(item)
                }
            }
        } else {
            downloadItem(item)
        }
    }

    // MARK: Delete

    private func deleteSelected() {
        let items = vm.selectedFileItems
        guard !items.isEmpty else { return }
        itemsToDelete = items
        showingDeleteConfirm = true
    }

    // MARK: Transfer Helpers

    private func downloadItem(_ item: FileItem) {
        guard let session = remoteSession else { return }
        guard let safeName = RemotePath.sanitizedFilename(item.name) else {
            appState.showError(title: "Unsafe filename", message: "Cannot save '\(item.name)' — name contains characters that aren't allowed.")
            return
        }

        let baseDir: URL
        switch Preferences.shared.downloadDestination {
        case .downloads:
            baseDir = LocalFileService.shared.downloadsDirectory()
        case .ask:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = safeName
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            // chosen is the final URL; respect it directly.
            appState.transferQueue.enqueue(
                connection: session.connection,
                direction: .download,
                localURL: chosen,
                remotePath: item.path
            )
            return
        }

        let dest = baseDir.appending(component: safeName)
        guard RemotePath.isContained(dest, in: baseDir) else {
            appState.showError(title: "Unsafe destination", message: "Refusing to save outside the chosen directory.")
            return
        }
        appState.transferQueue.enqueue(
            connection: session.connection,
            direction: .download,
            localURL: dest,
            remotePath: item.path
        )
    }

    /// Resolve the destination folder for downloads that don't go through the
    /// per-file save panel (folders, multi-selection). Asks once when the
    /// preference is "Ask each time".
    private func downloadDestinationDirectory() -> URL? {
        switch Preferences.shared.downloadDestination {
        case .downloads:
            return LocalFileService.shared.downloadsDirectory()
        case .ask:
            let panel = NSOpenPanel()
            panel.canChooseFiles          = false
            panel.canChooseDirectories    = true
            panel.canCreateDirectories    = true
            panel.allowsMultipleSelection = false
            panel.prompt                  = "Download Here"
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return url
        }
    }

    /// Download a mixed selection of files and folders into one destination,
    /// resolving the destination a single time.
    private func downloadMultiple(_ items: [FileItem]) {
        guard let session = remoteSession, !items.isEmpty,
              let baseDir = downloadDestinationDirectory() else { return }
        Task {
            for item in items where !item.isSymlink {
                if item.isDirectory {
                    do {
                        try await appState.transferQueue.enqueueFolderDownload(
                            connection: session.connection,
                            client: session.client,
                            remotePath: item.path,
                            folderName: item.name,
                            into: baseDir
                        )
                    } catch {
                        appState.showError(error)
                        return
                    }
                } else if let safeName = RemotePath.sanitizedFilename(item.name) {
                    let dest = baseDir.appending(component: safeName)
                    guard RemotePath.isContained(dest, in: baseDir) else { continue }
                    appState.transferQueue.enqueue(
                        connection: session.connection,
                        direction: .download,
                        localURL: dest,
                        remotePath: item.path
                    )
                }
            }
        }
    }

    private func quickLookRemote(_ item: FileItem) {
        guard let session = remoteSession else { return }
        guard let safeName = RemotePath.sanitizedFilename(item.name) else {
            appState.showError(title: "Unsafe filename", message: "Cannot preview '\(item.name)'.")
            return
        }
        // Dedicated subdirectory, cleared first so temp previews don't accumulate.
        let baseDir = FileManager.default.temporaryDirectory
            .appending(component: "QuickLook", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: baseDir)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let tmp = baseDir.appending(component: safeName)
        guard RemotePath.isContained(tmp, in: baseDir) else { return }
        Task {
            do {
                // Tracked in the queue: visible progress + working Cancel,
                // instead of the previous invisible unstoppable download.
                try await appState.transferQueue.runTracked(
                    connection: session.connection, direction: .download,
                    localURL: tmp, remotePath: item.path
                ) { progress in
                    try await session.client.download(
                        remotePath: item.path, to: tmp, resume: false, progress: progress
                    )
                }
                QuickLookCoordinator.shared.preview(url: tmp)
            } catch {
                if !(error is CancellationError) { appState.showError(error) }
            }
        }
    }

    private func uploadToRemote(session: RemoteSession) {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = true
        panel.canChooseDirectories    = true
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            let currentPath = vm.currentPath
            for url in panel.urls {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    Task { @MainActor in
                        do {
                            try await appState.transferQueue.enqueueFolderUpload(
                                connection: session.connection,
                                client: session.client,
                                folderURL: url,
                                remoteParent: currentPath
                            )
                        } catch { appState.showError(error) }
                    }
                } else {
                    let dest = currentPath.hasSuffix("/")
                        ? "\(currentPath)\(url.lastPathComponent)"
                        : "\(currentPath)/\(url.lastPathComponent)"
                    appState.transferQueue.enqueue(
                        connection: session.connection,
                        direction: .upload,
                        localURL: url,
                        remotePath: dest
                    )
                }
            }
        }
    }

    // MARK: Move / Copy / Duplicate

    /// Clear the drop highlight. Row-level drops (same-pane drags) are consumed
    /// by the table, so the pane delegate that lit the highlight never hears
    /// that the drag ended; the row handlers reset it themselves.
    private func clearDropHover() {
        isDropTargeted = false
        dropFolderFrame = nil
    }

    /// Remote items dropped on a remote folder row → server-side move (rename).
    private func moveRemote(_ refs: [RemoteFileRef], into folder: FileItem) {
        clearDropHover()
        guard let session = remoteSession else { return }
        Task {
            for ref in refs {
                let sourceParent = (ref.remotePath as NSString).deletingLastPathComponent
                // No-ops and traps: onto itself, into its current folder, or a
                // folder into its own descendant.
                guard ref.remotePath != folder.path, sourceParent != folder.path else { continue }
                if ref.isDirectory, (folder.path + "/").hasPrefix(ref.remotePath + "/") {
                    appState.showError(title: "Can't Move",
                                       message: "'\(ref.fileName)' can't be moved into itself.")
                    continue
                }
                let dest = RemotePath.join(folder.path, ref.fileName)
                if await session.client.fileExists(at: dest) {
                    appState.showError(title: "Can't Move",
                                       message: "'\(ref.fileName)' already exists in '\(folder.name)'.")
                    continue
                }
                do { try await session.client.rename(from: ref.remotePath, to: dest) }
                catch { appState.showError(error) }
            }
            await vm.refresh()
        }
    }

    /// Local URLs dropped on a local folder row: items dragged from this pane
    /// move (Finder same-volume semantics); anything from elsewhere is copied.
    private func moveOrCopyLocal(_ urls: [URL], into folder: FileItem) {
        clearDropHover()
        let folderURL = URL(fileURLWithPath: folder.path)
        for url in urls {
            guard url.path != folder.path,
                  !(folder.path + "/").hasPrefix(url.path + "/") else { continue }
            let dest = folderURL.appending(component: url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: dest.path) else {
                appState.showError(title: "Can't Move",
                                   message: "'\(url.lastPathComponent)' already exists in '\(folder.name)'.")
                continue
            }
            do {
                if url.deletingLastPathComponent().path == vm.currentPath {
                    try LocalFileService.shared.move(from: url, to: dest)
                } else {
                    try LocalFileService.shared.copy(from: url, to: dest)
                }
            } catch { appState.showError(error) }
        }
        Task { await vm.refresh() }
    }

    /// Remote items dropped on the local pane → download into `destDir` (the
    /// hovered folder, or the current directory) through the transfer queue
    /// (progress, conflict handling, retries).
    private func downloadRefs(_ refs: [RemoteFileRef], into destDir: URL) {
        guard let session = appState.activeSession else { return }
        Task {
            for ref in refs {
                if ref.isDirectory {
                    do {
                        try await appState.transferQueue.enqueueFolderDownload(
                            connection: session.connection, client: session.client,
                            remotePath: ref.remotePath, folderName: ref.fileName, into: destDir
                        )
                    } catch { appState.showError(error) }
                } else {
                    appState.transferQueue.enqueue(
                        connection: session.connection,
                        direction: .download,
                        localURL: destDir.appending(component: ref.fileName),
                        remotePath: ref.remotePath
                    )
                }
            }
        }
    }

    /// Duplicate an item next to itself ("name 2.ext"). Locally this is a copy;
    /// remotely it round-trips through a temp file (FTP/SFTP have no
    /// server-side copy), tracked in the transfer queue.
    private func duplicateItem(_ item: FileItem) {
        if vm.isLocal {
            let source = URL(fileURLWithPath: item.path)
            let dest = appState.transferQueue.uniqueLocalURL(for: source)
            do { try LocalFileService.shared.copy(from: source, to: dest) }
            catch { appState.showError(error) }
            Task { await vm.refresh() }
        } else {
            guard let session = remoteSession,
                  let safeName = RemotePath.sanitizedFilename(item.name) else { return }
            let tmpDir = FileManager.default.temporaryDirectory
                .appending(component: "Duplicate-\(UUID().uuidString)", directoryHint: .isDirectory)
            let tmp = tmpDir.appending(component: safeName)
            Task {
                do {
                    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                    try await appState.transferQueue.runTracked(
                        connection: session.connection, direction: .download,
                        localURL: tmp, remotePath: item.path
                    ) { progress in
                        try await session.client.download(
                            remotePath: item.path, to: tmp, resume: false, progress: progress
                        )
                    }
                    let target = await appState.transferQueue.uniqueRemotePath(
                        for: item.path, using: session.client
                    )
                    appState.transferQueue.enqueue(
                        connection: session.connection, direction: .upload,
                        localURL: tmp, remotePath: target
                    )
                } catch {
                    if !(error is CancellationError) { appState.showError(error) }
                }
            }
        }
    }

    /// Download a copy, open it in the default app, and auto-upload on save.
    private func editRemote(_ item: FileItem) {
        guard let session = remoteSession,
              let safeName = RemotePath.sanitizedFilename(item.name) else { return }
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "Edit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let local = dir.appending(component: safeName)
        guard RemotePath.isContained(local, in: dir) else { return }
        Task {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await appState.transferQueue.runTracked(
                    connection: session.connection, direction: .download,
                    localURL: local, remotePath: item.path
                ) { progress in
                    try await session.client.download(
                        remotePath: item.path, to: local, resume: false, progress: progress
                    )
                }
                RemoteEditManager.shared.beginEditing(
                    localURL: local, connection: session.connection, remotePath: item.path
                )
                NSWorkspace.shared.open(local)
            } catch {
                if !(error is CancellationError) { appState.showError(error) }
            }
        }
    }

    // MARK: Drag & Drop

    /// The droppable folder row under `location` (Table coordinate space) and
    /// its frame, or nil when the drag is over a file row or empty space.
    private func dropFolder(at location: CGPoint) -> (folder: FileItem, frame: CGRect?)? {
        guard let row = tableHandle.row(atTablePoint: location),
              let folder = FileItem.dropFolder(atRow: row, in: vm.displayedItems) else { return nil }
        return (folder, tableHandle.frame(ofRow: row))
    }

    /// Whether dropping `info` here would do anything (highlight + accept). A
    /// drag from the remote pane also exposes a file promise, so the
    /// remote-item payload is checked first and wins. Same-pane drags (local
    /// files on the local pane, remote items on the remote pane) are handled
    /// by the folder rows' own `dropDestination` and never arrive here, but
    /// the rules below stay complete in case that changes.
    private func canDrop(_ info: DropInfo, into folder: FileItem?) -> Bool {
        let remoteItems = info.hasItemsConforming(to: [.teleportRemoteItem])
        let localFiles  = !remoteItems && info.hasItemsConforming(to: [.fileURL])
        if vm.isLocal {
            // Remote items download into the folder or the current directory;
            // local files only ever move/copy into a folder.
            if remoteItems { return appState.activeSession != nil }
            if localFiles  { return folder != nil }
        } else {
            // Remote items move server-side into a folder only; local files
            // upload into the folder or the current directory.
            guard remoteSession != nil else { return false }
            if remoteItems { return folder != nil }
            if localFiles  { return true }
        }
        return false
    }

    /// Route a completed drop. `folder` is the hovered folder row, if any.
    private func performDrop(_ providers: [NSItemProvider], into folder: FileItem?) -> Bool {
        let remoteID = UTType.teleportRemoteItem.identifier
        let remote = providers.filter { $0.hasItemConformingToTypeIdentifier(remoteID) }
        // A remote drag's file promise is never honoured as a local file: that
        // would download-then-reupload the item onto itself.
        let local = remote.isEmpty
            ? providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            : []

        if vm.isLocal {
            if !remote.isEmpty {
                let dir = URL(fileURLWithPath: folder?.path ?? vm.currentPath)
                Task { downloadRefs(await loadRemoteRefs(remote), into: dir) }
                return true
            }
            if let folder, !local.isEmpty {
                Task { moveOrCopyLocal(await loadFileURLs(local), into: folder) }
                return true
            }
        } else {
            if !remote.isEmpty {
                guard let folder else { return false }
                Task { moveRemote(await loadRemoteRefs(remote), into: folder) }
                return true
            }
            if !local.isEmpty {
                let parent = folder?.path ?? vm.currentPath
                Task { uploadLocalURLs(await loadFileURLs(local), toRemoteParent: parent) }
                return true
            }
        }
        return false
    }

    /// Decode the in-app remote-item payloads carried by `providers`.
    private func loadRemoteRefs(_ providers: [NSItemProvider]) async -> [RemoteFileRef] {
        let typeID = UTType.teleportRemoteItem.identifier
        var refs: [RemoteFileRef] = []
        for provider in providers {
            let data: Data? = await withCheckedContinuation { cont in
                provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                    cont.resume(returning: data)
                }
            }
            if let data, let ref = try? JSONDecoder().decode(RemoteFileRef.self, from: data) {
                refs.append(ref)
            }
        }
        return refs
    }

    /// Resolve the file URLs carried by `providers` (Finder or the local pane).
    private func loadFileURLs(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { cont in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data else { return cont.resume(returning: nil) }
                    cont.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                }
            }
            if let url { urls.append(url) }
        }
        return urls
    }

    /// Upload local files/folders into `remoteParent` through the transfer
    /// queue. Folders are uploaded recursively.
    private func uploadLocalURLs(_ urls: [URL], toRemoteParent remoteParent: String) {
        guard let session = remoteSession else { return }
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                Task {
                    do {
                        try await appState.transferQueue.enqueueFolderUpload(
                            connection: session.connection,
                            client: session.client,
                            folderURL: url,
                            remoteParent: remoteParent
                        )
                    } catch { appState.showError(error) }
                }
            } else {
                appState.transferQueue.enqueue(
                    connection: session.connection,
                    direction: .upload,
                    localURL: url,
                    remotePath: RemotePath.join(remoteParent, url.lastPathComponent)
                )
            }
        }
    }
}

// MARK: - Pane Drop Delegate

/// Pane-wide drop handling for a file list: drags from the other pane or from
/// Finder. Tracks the folder row under the drag (via `TableHandle`) so the
/// view can highlight it and route the drop into it, and falls back to the
/// pane's current directory elsewhere. Drags that originate in the same table
/// don't reach a pane-level drop handler; those go through the folder rows'
/// `dropDestination` instead.
struct PaneDropDelegate: DropDelegate {
    let types: [UTType]
    let folderAt: (CGPoint) -> (folder: FileItem, frame: CGRect?)?
    let canDrop: (DropInfo, FileItem?) -> Bool
    let hover: (_ targeted: Bool, _ folderFrame: CGRect?) -> Void
    let perform: ([NSItemProvider], FileItem?) -> Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: types) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = folderAt(info.location)
        guard canDrop(info, target?.folder) else {
            hover(false, nil)
            return DropProposal(operation: .cancel)
        }
        hover(true, target?.frame)
        // Always propose `.copy`: SwiftUI's `draggable` sources only permit
        // copy, so proposing `.move` makes AppKit refuse the drop outright —
        // even for drops that end up as server-side or same-volume moves.
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) { hover(false, nil) }

    func performDrop(info: DropInfo) -> Bool {
        hover(false, nil)
        let target = folderAt(info.location)
        guard canDrop(info, target?.folder) else { return false }
        return perform(info.itemProviders(for: types), target?.folder)
    }
}

// MARK: - Quick Look Coordinator

final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()
    private var urls: [URL] = []

    func preview(url: URL) {
        urls = [url]
        QLPreviewPanel.shared().dataSource = self
        QLPreviewPanel.shared().delegate   = self
        QLPreviewPanel.shared().reloadData()
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}

// MARK: - Table Bridge

/// Weak access to the AppKit table behind a SwiftUI `Table`, for the things
/// SwiftUI won't expose: which row sits under a point (drop targeting) and
/// where that row is drawn (drop highlight). Only ever touched on the main
/// thread (AppKit views and SwiftUI drop callbacks).
final class TableHandle {
    weak var tableView: NSTableView?
    /// The bridge's host view: shares the Table's frame and is flipped, so its
    /// coordinates match SwiftUI's (top-left origin) — what `DropInfo.location`
    /// reports.
    weak var anchor: NSView?

    /// The row under `point` (Table coordinate space), or nil for none.
    func row(atTablePoint point: CGPoint) -> Int? {
        guard let anchor, let tableView else { return nil }
        let row = tableView.row(at: tableView.convert(point, from: anchor))
        return row >= 0 ? row : nil
    }

    /// Frame of `row` in the Table coordinate space.
    func frame(ofRow row: Int) -> CGRect? {
        guard let anchor, let tableView else { return nil }
        return anchor.convert(tableView.rect(ofRow: row), from: tableView)
    }
}

/// Reaches the backing `NSTableView` of a SwiftUI `Table` to add what SwiftUI
/// lacks: double-click-to-open (via the native `doubleAction`; a SwiftUI tap
/// gesture on rows would suppress single-click selection) and row geometry for
/// drop targeting (published through `handle`). The host view is
/// click-transparent (`hitTest` → nil), so it never interferes with selection
/// or dragging.
///
/// `onDoubleClick` receives the clicked row index (matching the data order).
struct TableBridge: NSViewRepresentable {
    /// Receives the table for drop targeting; nil when only double-click is needed.
    var handle: TableHandle? = nil
    let onDoubleClick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle, onDoubleClick: onDoubleClick) }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.anchor = view
        handle?.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDoubleClick = onDoubleClick
        // Defer: the table may not be in the hierarchy yet when first created.
        DispatchQueue.main.async { context.coordinator.connectIfNeeded() }
    }

    final class Coordinator: NSObject {
        let handle: TableHandle?
        var onDoubleClick: (Int) -> Void
        weak var anchor: NSView?
        weak var tableView: NSTableView?

        init(handle: TableHandle?, onDoubleClick: @escaping (Int) -> Void) {
            self.handle = handle
            self.onDoubleClick = onDoubleClick
        }

        func connectIfNeeded() {
            if let tv = tableView {
                if tv.target !== self || tv.doubleAction != #selector(handleDoubleClick) {
                    tv.target = self
                    tv.doubleAction = #selector(handleDoubleClick)
                }
                return
            }
            guard let anchor, let window = anchor.window,
                  let anchorFrame = anchor.superview?.convert(anchor.frame, to: nil),
                  let content = window.contentView else { return }

            // Pick the NSTableView whose window-space frame overlaps this view's
            // most — i.e. the table this handler is the background of (each pane
            // and the sidebar own a distinct region).
            var best: (table: NSTableView, area: CGFloat)?
            func search(_ view: NSView) {
                if let tv = view as? NSTableView {
                    let f = tv.convert(tv.bounds, to: nil).intersection(anchorFrame)
                    let area = f.width * f.height
                    if area > 0, best == nil || area > best!.area { best = (tv, area) }
                }
                view.subviews.forEach(search)
            }
            search(content)

            guard let tv = best?.table else { return }
            tableView = tv
            handle?.tableView = tv
            tv.target = self
            tv.doubleAction = #selector(handleDoubleClick)
        }

        @objc private func handleDoubleClick() {
            guard let row = tableView?.clickedRow, row >= 0 else { return }
            onDoubleClick(row)
        }
    }

    /// Transparent to hit-testing so it never captures clicks meant for the
    /// table. Flipped so its coordinates match SwiftUI's (see `TableHandle`).
    final class PassthroughView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Remote File Drag (drag-to-download)

/// Lets a remote file be dragged out to Finder/Desktop: the file is downloaded
/// on demand when the drop is accepted, then handed to the destination. Uses a
/// `FileRepresentation` whose export closure runs at drop time, so nothing is
/// transferred until the user actually drops.
struct RemoteFileDrag: Transferable, Sendable {
    let client: RemoteClient
    let connection: Connection
    let queue: TransferQueueViewModel
    let remotePath: String
    let fileName: String

    var ref: RemoteFileRef {
        RemoteFileRef(remotePath: remotePath, fileName: fileName, isDirectory: false)
    }

    static var transferRepresentation: some TransferRepresentation {
        // In-app first: the local pane asks for the lightweight ref, so a
        // pane-to-pane drop never triggers the blocking temp-file export.
        ProxyRepresentation(exporting: \.ref)
        // Finder/Desktop drops still get real file contents at drop time.
        FileRepresentation(exportedContentType: .data) { drag in
            try await drag.download()
        }
    }

    private func download() async throws -> SentTransferredFile {
        // Unique per-drag temp dir so concurrent drags don't collide; cleaned up
        // by the system's temp reaping.
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "Drag-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(component: fileName)
        // Tracked in the queue so the export shows progress and can be cancelled.
        try await queue.runTracked(
            connection: connection, direction: .download,
            localURL: dest, remotePath: remotePath
        ) { progress in
            try await client.download(remotePath: remotePath, to: dest, resume: false, progress: progress)
        }
        return SentTransferredFile(dest)
    }
}

// MARK: - Remote Folder Drag (drag-to-download a whole folder)

/// Folder counterpart of `RemoteFileDrag`: in-app drops use the lightweight
/// ref (recursive download through the queue); dropping on Finder exports the
/// folder by recursively downloading it to a temp directory first.
struct RemoteFolderDrag: Transferable, Sendable {
    let client: RemoteClient
    let connection: Connection
    let queue: TransferQueueViewModel
    let remotePath: String
    let folderName: String

    var ref: RemoteFileRef {
        RemoteFileRef(remotePath: remotePath, fileName: folderName, isDirectory: true)
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.ref)
        FileRepresentation(exportedContentType: .folder) { drag in
            try await drag.downloadTree()
        }
    }

    private func downloadTree() async throws -> SentTransferredFile {
        let base = FileManager.default.temporaryDirectory
            .appending(component: "Drag-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(component: folderName)

        // Walk the remote tree first so file downloads can report an overall
        // byte total. Same guards as the queue's folder download: sanitized
        // names, containment, skipped symlinks, capped entry count.
        var pendingDirs: [(remote: String, local: URL)] = [(remotePath, root)]
        var files: [(remote: String, local: URL)] = []
        var totalBytes: Int64 = 0
        while let (remoteDir, localDir) = pendingDirs.popLast() {
            try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            for item in try await client.listDirectory(at: remoteDir) {
                guard let name = RemotePath.sanitizedFilename(item.name), !item.isSymlink else { continue }
                let childLocal = localDir.appending(component: name)
                guard RemotePath.isContained(childLocal, in: localDir) else { continue }
                if item.isDirectory {
                    pendingDirs.append((item.path, childLocal))
                } else {
                    files.append((item.path, childLocal))
                    totalBytes += item.size ?? 0
                }
                if files.count + pendingDirs.count > TransferQueueViewModel.folderTransferLimit {
                    throw TransferQueueViewModel.FolderTransferError.tooLarge
                }
            }
        }

        // One queue row tracks the whole folder export (progress + Cancel).
        let fileList = files
        let expectedTotal = totalBytes
        try await queue.runTracked(
            connection: connection, direction: .download,
            localURL: root, remotePath: remotePath
        ) { progress in
            var doneBytes: Int64 = 0
            for (remote, local) in fileList {
                try await client.download(remotePath: remote, to: local, resume: false) { bytes, _ in
                    progress(doneBytes + bytes, expectedTotal)
                }
                doneBytes += (try? FileManager.default
                    .attributesOfItem(atPath: local.path)[.size] as? Int64) ?? 0
            }
            progress(expectedTotal, expectedTotal)
        }
        return SentTransferredFile(root)
    }
}

