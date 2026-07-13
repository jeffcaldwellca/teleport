import Foundation
import SwiftUI

// MARK: - Sort Options

enum SortKey: String, CaseIterable {
    case name, size, date, kind
    var label: String { rawValue.capitalized }
}

// MARK: - BrowserViewModel

/// Manages the state of a single file-browser pane (either local or remote).
@Observable
@MainActor
final class BrowserViewModel {

    // Navigation
    var currentPath: String
    var history:     [String] = []
    var forwardStack:[String] = []

    // Content
    private var allItems: [FileItem] = [] { didSet { recomputeDisplayed() } }
    var isLoading     = false
    var loadError:    String?   = nil

    /// True once at least one listing has succeeded. Distinguishes "not loaded
    /// yet" (show a spinner) from "loaded and genuinely empty" (show empty state),
    /// so the empty-folder placeholder never flashes before the first load.
    private(set) var hasLoaded = false

    /// Path of the most recent *failed* navigation, so "Retry" re-attempts the
    /// folder the user actually wanted rather than the one we're still in.
    private var attemptedPath: String?

    /// Cached, derived view of `allItems`. Recomputed only when an input
    /// (items, filter, sort, hidden-visibility) actually changes — not on every
    /// SwiftUI read — so large directories don't re-sort on each render pass.
    private(set) var displayedItems: [FileItem] = []

    // Selection — keyed by FileItem.id (path), so selection survives refresh.
    var selectedItems: Set<String> = []

    // Sort & filter
    var sortKey:       SortKey  = .name { didSet { recomputeDisplayed() } }
    var sortAscending  = true           { didSet { recomputeDisplayed() } }
    var filterText:    String   = ""    { didSet { scheduleFilterRecompute() } }
    var showHidden:    Bool     = Preferences.shared.showHiddenByDefault {
        didSet { recomputeDisplayed() }
    }
    private var filterDebounce: Task<Void, Never>?

    // Rename in-place
    var renamingItem:  FileItem? = nil
    var renameText:    String   = ""

    private let client: RemoteClient?      // nil → local browser
    let isLocal: Bool

    // MARK: Local init

    convenience init(localPath: String) {
        self.init(client: nil, initialPath: localPath)
    }

    // MARK: Remote init

    init(client: RemoteClient?, initialPath: String) {
        self.client      = client
        self.isLocal     = client == nil
        self.currentPath = initialPath
    }

    // MARK: - Navigation

    /// How a successful load should mutate the back/forward history. History is
    /// only updated *after* the listing succeeds, so a failed navigation never
    /// corrupts back/forward or moves the breadcrumb to a folder we never reached.
    private enum NavMode { case push, back, forward, reload }

    func navigate(to path: String) async {
        guard path != currentPath else { return }
        await load(path: path, mode: .push)
    }

    func goBack() async {
        guard let prev = history.last else { return }
        await load(path: prev, mode: .back)
    }

    func goForward() async {
        guard let next = forwardStack.last else { return }
        await load(path: next, mode: .forward)
    }

    func goUp() async {
        let parent = (currentPath as NSString).deletingLastPathComponent
        guard parent != currentPath, !parent.isEmpty else { return }
        await navigate(to: parent)
    }

    // MARK: - Load

    /// External entry point used to seed a pane at a known path (e.g. on connect).
    func loadDirectory(path: String) async {
        await load(path: path, mode: .reload)
    }

    func refresh() async {
        await load(path: currentPath, mode: .reload)
    }

    /// List a remote directory, transparently reconnecting once if the session
    /// looks dropped (idle timeout, network blip) so browsing self-heals.
    private func remoteListing(_ client: RemoteClient, at path: String) async throws -> [FileItem] {
        do {
            return try await client.listDirectory(at: path)
        } catch {
            guard Self.isLikelyConnectionDrop(error) else { throw error }
            try await client.connect()                  // re-establish in place
            return try await client.listDirectory(at: path)
        }
    }

    /// Distinguishes a dropped/unreachable connection (worth a reconnect) from a
    /// logical error like permission-denied or not-found (don't reconnect).
    private static func isLikelyConnectionDrop(_ error: Error) -> Bool {
        if let e = error as? RemoteClientError {
            switch e {
            case .permissionDenied, .fileNotFound, .unsupported, .authenticationFailed: return false
            default: return true
            }
        }
        if let e = error as? FTPError {
            switch e {
            case .permissionDenied, .authFailed: return false
            default: return true
            }
        }
        return true   // unknown (e.g. NIO/Citadel channel-closed) → assume drop
    }

    /// Re-attempts the most recently failed navigation (falls back to the
    /// current folder), used by the error state's "Retry" button.
    func retry() async {
        await load(path: attemptedPath ?? currentPath, mode: .reload)
    }

    private func load(path: String, mode: NavMode) async {
        let previous = currentPath
        isLoading = true
        loadError = nil
        // Navigating away discards the selection; a same-folder reload keeps it
        // (pruned below to items that still exist), so refreshes — including
        // the automatic post-transfer ones — don't yank the user's selection.
        if mode != .reload { selectedItems.removeAll() }
        do {
            let raw: [FileItem]
            if isLocal {
                raw = try LocalFileService.shared.listDirectory(at: URL(fileURLWithPath: path))
            } else {
                guard let client else { throw RemoteClientError.notConnected }
                raw = try await remoteListing(client, at: path)
            }
            // Commit navigation only now that the listing succeeded.
            switch mode {
            case .push:    history.append(previous); forwardStack.removeAll()
            case .back:    if !history.isEmpty { history.removeLast() }; forwardStack.append(previous)
            case .forward: if !forwardStack.isEmpty { forwardStack.removeLast() }; history.append(previous)
            case .reload:  break
            }
            currentPath   = path
            attemptedPath = nil
            allItems      = raw
            hasLoaded     = true
            if mode == .reload {
                selectedItems.formIntersection(Set(raw.map(\.id)))
            }
        } catch {
            loadError     = error.localizedDescription
            attemptedPath = path
            // Leave currentPath / history / allItems untouched — we're still in
            // the previous folder as far as the user is concerned.
        }
        isLoading = false
    }

    // MARK: - Sort / Filter

    func setSort(_ key: SortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            sortAscending = true
        }
        // didSet on sortKey / sortAscending triggers recomputeDisplayed()
    }

    /// Apply an explicit sort (used by the Table's clickable column headers).
    /// `displayedItems` keeps its own "directories first" rule on top of this.
    func applySort(key: SortKey, ascending: Bool) {
        if sortKey != key { sortKey = key }
        if sortAscending != ascending { sortAscending = ascending }
    }

    /// Debounce filter typing so a large directory doesn't re-filter+sort on
    /// every keystroke. Clearing the field applies immediately for snappy reset.
    private func scheduleFilterRecompute() {
        filterDebounce?.cancel()
        guard !filterText.isEmpty else {
            recomputeDisplayed()
            return
        }
        filterDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.recomputeDisplayed()
        }
    }

    private func recomputeDisplayed() {
        let filtered = allItems.filter { item in
            (showHidden || !item.isHidden) &&
            (filterText.isEmpty || item.name.localizedCaseInsensitiveContains(filterText))
        }
        displayedItems = sort(filtered)
    }

    private func sort(_ raw: [FileItem]) -> [FileItem] {
        raw.sorted { a, b in
            // Directories first
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let cmp: Bool
            switch sortKey {
            case .name: cmp = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .size: cmp = (a.size ?? 0) < (b.size ?? 0)
            case .date:
                if let da = a.modifiedDate, let db = b.modifiedDate { cmp = da < db }
                else { cmp = a.name < b.name }
            case .kind: cmp = a.contentType.identifier < b.contentType.identifier
            }
            return sortAscending ? cmp : !cmp
        }
    }

    // MARK: - Selection Helpers

    var selectedFileItems: [FileItem] {
        allItems.filter { selectedItems.contains($0.id) }
    }

    func selectAll() { selectedItems = Set(displayedItems.map(\.id)) }
    func clearSelection() { selectedItems.removeAll() }

    /// True when `path` can be listed — used to decide whether a remote
    /// symlink points at a directory (listings report links with lstat
    /// semantics, so `isDirectory` is false even for links to folders).
    func probeDirectory(_ path: String) async -> Bool {
        guard let client else { return false }
        return (try? await client.listDirectory(at: path)) != nil
    }

    // MARK: - File Operations

    func createDirectory(named name: String) async throws {
        guard let safeName = RemotePath.sanitizedFilename(name) else {
            throw RemotePathError.unsafeName(name)
        }
        let newPath = "\(currentPath)/\(safeName)"
        if isLocal {
            try LocalFileService.shared.createDirectory(at: URL(fileURLWithPath: newPath))
        } else {
            try await client?.createDirectory(at: newPath)
        }
        await refresh()
    }

    func delete(items toDelete: [FileItem]) async throws {
        for item in toDelete {
            if isLocal {
                try LocalFileService.shared.delete(at: URL(fileURLWithPath: item.path))
            } else if let client {
                try await Self.deleteRemote(item, client: client, depth: 0)
            }
        }
        await refresh()
    }

    /// Remote servers won't delete non-empty directories, so recurse into the
    /// children first. Symlinks are deleted as entries (never followed), and a
    /// depth cap defends against cyclic listings from a misbehaving server.
    private static func deleteRemote(_ item: FileItem, client: RemoteClient, depth: Int) async throws {
        if item.isDirectory && !item.isSymlink {
            guard depth < 32 else {
                throw RemoteClientError.transferFailed("Folder nesting too deep to delete safely")
            }
            for child in try await client.listDirectory(at: item.path) {
                try await deleteRemote(child, client: client, depth: depth + 1)
            }
            try await client.delete(at: item.path, isDirectory: true)
        } else {
            try await client.delete(at: item.path, isDirectory: false)
        }
    }

    func rename(item: FileItem, to newName: String) async throws {
        guard let safeName = RemotePath.sanitizedFilename(newName) else {
            throw RemotePathError.unsafeName(newName)
        }
        let newPath = (item.path as NSString).deletingLastPathComponent + "/" + safeName
        if isLocal {
            try LocalFileService.shared.rename(
                from: URL(fileURLWithPath: item.path),
                to:   URL(fileURLWithPath: newPath)
            )
        } else {
            try await client?.rename(from: item.path, to: newPath)
        }
        await refresh()
    }
}
