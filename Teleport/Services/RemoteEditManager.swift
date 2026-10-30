import Foundation
import TeleportKit

/// Tracks remote files opened for local editing ("Edit…" in the remote pane):
/// the downloaded copy is watched, and every save is auto-uploaded back to the
/// server through the transfer queue.
///
/// Watching is done by polling the file's modification time rather than a
/// file-descriptor source: editors typically save atomically (write-to-temp +
/// rename), which silently detaches fd-based watchers.
///
/// Sessions outlive the app: an editor window can stay open across a quit,
/// and its next save should still reach the server. They are saved, picked
/// up again at launch (`restore`), and their folders spared by the launch
/// sweep of temporary files.
@MainActor
final class RemoteEditManager {

    static let shared = RemoteEditManager()

    private struct Session: Codable {
        let localURL: URL
        let connection: Connection
        let remotePath: String
        /// Most recent mtime observed on disk (may still be mid-save).
        var lastSeenMtime: Date
        /// The mtime whose contents were last enqueued for upload.
        var lastUploadedMtime: Date
        /// Ticks the file has been missing (editor may briefly remove it
        /// during an atomic save); evicted after several consecutive misses.
        var missingTicks: Int = 0
    }

    private var sessions: [Session] = [] { didSet { persist() } }
    private var pollTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private static let defaultsKey = "com.teleport.remoteEditSessions"

    /// A session whose copy hasn't been touched for this long is dropped at
    /// launch, and its folder swept.
    static let maximumIdle: TimeInterval = 7 * 24 * 60 * 60

    /// Injected by the UI at startup. Returns false when the upload was
    /// dropped (e.g. an identical upload is already pending) so the change
    /// stays marked dirty and is retried on a later tick.
    var enqueueUpload: ((Connection, URL, String) -> Bool)?

    /// Injected by the UI at startup: the saved connection with this id as it
    /// is now, or nil if it has been deleted.
    var currentConnection: ((UUID) -> Connection?)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func beginEditing(localURL: URL, connection: Connection, remotePath: String) {
        let mtime = Self.mtime(of: localURL) ?? Date()
        sessions.removeAll { $0.localURL == localURL }
        sessions.append(Session(
            localURL: localURL, connection: connection, remotePath: remotePath,
            lastSeenMtime: mtime, lastUploadedMtime: mtime
        ))
        startPolling()
    }

    /// The local copy already open for this remote file, if any. Editing the
    /// file again should reopen it: a second copy would leave the first
    /// editor window's next save to upload older content over newer.
    func existingCopy(connectionID: UUID, remotePath: String) -> URL? {
        sessions.first {
            $0.connection.id == connectionID && $0.remotePath == remotePath
                && FileManager.default.fileExists(atPath: $0.localURL.path)
        }?.localURL
    }

    /// Picks up the sessions of an earlier run whose copies are still there
    /// and recently touched, and returns their folders, which the launch
    /// sweep must leave alone.
    @discardableResult
    func restore(now: Date = Date()) -> Set<URL> {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode([Session].self, from: data) else { return [] }
        sessions = saved.filter { session in
            guard let mtime = Self.mtime(of: session.localURL) else { return false }
            return now.timeIntervalSince(mtime) < Self.maximumIdle
        }.map { session in
            var session = session
            session.missingTicks = 0
            return session
        }
        if !sessions.isEmpty { startPolling() }
        return Set(sessions.map { $0.localURL.deletingLastPathComponent().standardizedFileURL })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        var evict: [URL] = []
        for i in sessions.indices {
            guard let current = Self.mtime(of: sessions[i].localURL) else {
                sessions[i].missingTicks += 1
                if sessions[i].missingTicks >= 5 { evict.append(sessions[i].localURL) }
                continue
            }
            sessions[i].missingTicks = 0

            if current != sessions[i].lastSeenMtime {
                // Changed since last look — wait one tick for the save to settle
                // so we never upload a half-written file.
                sessions[i].lastSeenMtime = current
                continue
            }
            if current != sessions[i].lastUploadedMtime {
                let s = sessions[i]
                // Upload only to the server the file came from. The session
                // keeps the connection as it was when editing began (and across
                // relaunches); if it has since been deleted or pointed at
                // another server or account, a save would otherwise go there
                // with whatever password the connection now has.
                guard let resolve = currentConnection else { continue }   // not wired up yet
                guard let connection = resolve(s.connection.id), connection.sameEndpoint(as: s.connection) else {
                    evict.append(s.localURL)
                    continue
                }
                if enqueueUpload?(connection, s.localURL, s.remotePath) == true {
                    sessions[i].lastUploadedMtime = current
                }
            }
        }
        sessions.removeAll { evict.contains($0.localURL) }
        if sessions.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private static func mtime(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
