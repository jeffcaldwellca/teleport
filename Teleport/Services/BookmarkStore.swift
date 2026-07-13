import Foundation
import Observation

/// Persists security-scoped bookmark data so the app can re-open user-chosen
/// files (SSH keys, local pane root, upload sources) across launches under
/// the App Sandbox.
///
/// Stored as a JSON map of `name → bookmarkData (base64)` under
/// `Application Support/Teleport/bookmarks.json`.
@MainActor
final class BookmarkStore {

    static let shared = BookmarkStore()

    /// Active security-scoped accesses we've started, so we can stop them
    /// on app exit (best effort — sandbox extensions are cleaned up
    /// automatically on process death too).
    private var activeAccesses: [URL] = []

    private struct File: Codable {
        var schemaVersion: Int = 1
        var bookmarks: [String: Data] = [:]
    }

    private var file = File()
    private var loaded = false

    private init() {}

    // MARK: - Save / load

    /// Capture a security-scoped bookmark for `url` and persist it under `name`.
    /// `name` should be a stable identifier (e.g. `"sshKey:<connection-uuid>"` or `"localRoot"`).
    func save(_ url: URL, name: String) throws {
        ensureLoaded()
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        file.bookmarks[name] = data
        try persist()
    }

    /// Resolve a previously-saved bookmark and start a security-scoped access.
    /// Returns the resolved URL. If the bookmark is stale, it's refreshed transparently.
    /// The caller is responsible for treating the returned URL as security-scoped —
    /// any reads/writes against it must happen between this call and the matching
    /// `stopAccessing(_:)`. For convenience, `withAccess(_:body:)` handles that.
    func resolve(name: String) throws -> URL? {
        ensureLoaded()
        guard let data = file.bookmarks[name] else { return nil }

        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        if stale {
            // Re-record the bookmark for next time.
            try save(url, name: name)
        }
        guard url.startAccessingSecurityScopedResource() else {
            return nil
        }
        activeAccesses.append(url)
        return url
    }

    /// Convenience: resolve the bookmark, run `body`, and stop access regardless
    /// of throw. Use this when the access is short-lived.
    func withAccess<T>(name: String, _ body: (URL) throws -> T) throws -> T? {
        guard let url = try resolve(name: name) else { return nil }
        defer { stopAccessing(url) }
        return try body(url)
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
        if let idx = activeAccesses.firstIndex(of: url) {
            activeAccesses.remove(at: idx)
        }
    }

    func remove(name: String) throws {
        ensureLoaded()
        file.bookmarks.removeValue(forKey: name)
        try persist()
    }

    /// Copy the bookmark stored under `name` to `newName` (no-op when absent).
    /// Used when duplicating a connection so its SSH-key access carries over.
    func duplicate(name: String, as newName: String) throws {
        ensureLoaded()
        guard let data = file.bookmarks[name] else { return }
        file.bookmarks[newName] = data
        try persist()
    }

    // MARK: - Storage

    private static var storeURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = support.appending(component: "Teleport")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(component: "bookmarks.json")
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let url = Self.storeURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(File.self, from: data) else {
            return
        }
        file = decoded
    }

    private func persist() throws {
        guard let url = Self.storeURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: url, options: [.atomic])
    }
}

// MARK: - Bookmark name conventions

extension BookmarkStore {
    static func sshKeyName(for connectionID: UUID) -> String {
        "sshKey:\(connectionID.uuidString)"
    }

    static let localRootName = "localRoot"
}
