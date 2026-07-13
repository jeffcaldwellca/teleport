import Foundation

/// Tracks remote files opened for local editing ("Edit…" in the remote pane):
/// the downloaded copy is watched, and every save is auto-uploaded back to the
/// server through the transfer queue.
///
/// Watching is done by polling the file's modification time rather than a
/// file-descriptor source: editors typically save atomically (write-to-temp +
/// rename), which silently detaches fd-based watchers.
@MainActor
final class RemoteEditManager {

    static let shared = RemoteEditManager()

    private struct Session {
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

    private var sessions: [Session] = []
    private var pollTask: Task<Void, Never>?

    /// Injected by the UI at startup. Returns false when the upload was
    /// dropped (e.g. an identical upload is already pending) so the change
    /// stays marked dirty and is retried on a later tick.
    var enqueueUpload: ((Connection, URL, String) -> Bool)?

    private init() {}

    func beginEditing(localURL: URL, connection: Connection, remotePath: String) {
        let mtime = Self.mtime(of: localURL) ?? Date()
        sessions.removeAll { $0.localURL == localURL }
        sessions.append(Session(
            localURL: localURL, connection: connection, remotePath: remotePath,
            lastSeenMtime: mtime, lastUploadedMtime: mtime
        ))
        startPolling()
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
                if enqueueUpload?(s.connection, s.localURL, s.remotePath) == true {
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
