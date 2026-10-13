import Foundation
import Observation
import TeleportKit

/// State behind the Sync Folders sheet: compare a local folder with a remote
/// one, show the plan, then carry it out through the transfer queue.
@Observable
@MainActor
final class SyncViewModel: Identifiable {

    enum Phase: Equatable {
        case idle
        case comparing
        /// A plan is ready to review.
        case ready
        case applying
        case done(String)
        case failed(String)
    }

    let id = UUID()
    let connection: Connection
    let localRoot: URL
    let remoteRoot: String

    // Changing what is being asked for invalidates any plan made earlier.
    var direction: SyncDirection = .upload { didSet { if direction != oldValue { invalidate() } } }
    var deleteExtraneous = false          { didSet { if deleteExtraneous != oldValue { invalidate() } } }
    var sizeOnly = false                  { didSet { if sizeOnly != oldValue { invalidate() } } }
    /// Patterns to skip, as typed: separated by commas or new lines
    /// (`node_modules, *.log`). See `FolderSync.matches` for what they mean.
    var excludeText: String               { didSet { if excludeText != oldValue { invalidate() } } }

    static func patterns(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private(set) var phase: Phase = .idle
    private(set) var plan: SyncPlan?

    /// Called once a plan has been carried out (transfers queued, deletions
    /// done), so the panes can catch up.
    var onApplied: (() -> Void)?

    private let queue: TransferQueueViewModel
    private let trash: (URL) throws -> Void
    /// Bumped whenever the settings change, so a comparison that finishes
    /// late can tell its answer is no longer wanted.
    private var generation = 0

    init(
        connection: Connection, localRoot: URL, remoteRoot: String, queue: TransferQueueViewModel,
        excludeText: String = "",
        trash: @escaping (URL) throws -> Void = { try LocalFileService.shared.delete(at: $0) }
    ) {
        self.excludeText = excludeText
        self.connection = connection
        self.localRoot = localRoot
        self.remoteRoot = remoteRoot
        self.queue = queue
        self.trash = trash
    }

    private var options: SyncOptions {
        SyncOptions(deleteExtraneous: deleteExtraneous, sizeOnly: sizeOnly,
                    excludes: Self.patterns(from: excludeText))
    }

    private func invalidate() {
        generation += 1
        plan = nil
        if phase != .applying { phase = .idle }
    }

    // MARK: - Compare

    /// Scan both sides and work out the plan. Changes nothing.
    func compare() async {
        generation += 1
        let asked = generation
        plan = nil
        deletionsCalledOff = false
        phase = .comparing
        let (localRoot, remoteRoot, direction, options) = (localRoot, remoteRoot, direction, options)
        do {
            // On a connection of its own: a big tree takes a while, and the
            // browsing session should stay usable (and closable) meanwhile.
            let comparison = try await queue.withOwnConnection(to: connection) { client in
                try await FolderSync.compare(localRoot: localRoot, remoteRoot: remoteRoot, client: client,
                                             direction: direction, options: options)
            }
            guard asked == generation else { return }
            plan = comparison.plan
            phase = .ready
        } catch {
            guard asked == generation else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Apply

    /// True while the transfers are running and deletions are waiting on them.
    private(set) var isWaitingToDelete = false
    private var deletionsCalledOff = false

    /// Keep the transfers, drop the deletions. Usable while they are still
    /// waiting for the transfers to finish.
    func skipDeletions() {
        deletionsCalledOff = true
    }

    /// Carry out the reviewed plan: folders first, then the transfers through
    /// the queue (as overwrites — the plan already decided), and only once
    /// every one of those has succeeded, the deletions.
    ///
    /// That order matters. A renamed file shows up as "transfer the new
    /// name, delete the old": deleting first would, if the transfer then
    /// failed or was cancelled, leave the destination with neither.
    func apply() async {
        guard phase == .ready, let plan else { return }
        phase = .applying
        let remoteRoot = remoteRoot
        let remotePath: @Sendable (String) -> String = { FolderSync.joined(remoteRoot, $0) }

        do {
            switch plan.direction {
            case .upload:
                let folders = plan.directories.map { remotePath($0.relativePath) }
                try await queue.withOwnConnection(to: connection) { client in
                    // May exist already; a genuinely missing folder shows up
                    // as failed uploads in the queue.
                    try? await client.createDirectory(at: remoteRoot)
                    for folder in folders { try? await client.createDirectory(at: folder) }
                }
            case .download:
                try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
                for folder in plan.directories {
                    try FileManager.default.createDirectory(at: localRoot.appending(path: folder.relativePath),
                                                            withIntermediateDirectories: true)
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let transfers = queue.enqueueBatch(
            connection: connection,
            direction: plan.direction == .upload ? .upload : .download,
            items: plan.transfers.map { (localRoot.appending(path: $0.relativePath), remotePath($0.relativePath)) },
            conflictBehavior: .overwrite
        )
        self.plan = nil

        var deletionOutcome: String?
        if !plan.deletions.isEmpty {
            isWaitingToDelete = true
            // A paused transfer isn't going to finish on its own; don't wait on it.
            while transfers.contains(where: { !$0.status.isFinal && $0.status != .paused }), !deletionsCalledOff {
                try? await Task.sleep(for: .milliseconds(100))
            }
            isWaitingToDelete = false

            let unfinished = transfers.filter { $0.status != .completed }.count
            if deletionsCalledOff {
                deletionOutcome = "Deletions were skipped."
            } else if unfinished > 0 {
                deletionOutcome = "\(unfinished) transfer\(unfinished == 1 ? "" : "s") didn\u{2019}t finish, so nothing was deleted."
            } else {
                let failed = await delete(plan.deletions, remotePath: remotePath, uploading: plan.direction == .upload)
                let deleted = plan.deletions.count - failed
                deletionOutcome = "\(deleted) item\(deleted == 1 ? "" : "s") deleted"
                    + (failed > 0 ? ", \(failed) could not be deleted." : ".")
            }
        }

        var parts: [String] = []
        if !transfers.isEmpty {
            parts.append("\(transfers.count) transfer\(transfers.count == 1 ? "" : "s") \(plan.deletions.isEmpty ? "queued" : "run").")
        }
        if let deletionOutcome { parts.append(deletionOutcome) }
        phase = .done(parts.isEmpty ? "Nothing needed doing." : parts.joined(separator: " "))
        onApplied?()
    }

    /// Returns how many deletions failed.
    private func delete(_ deletions: [SyncAction], remotePath: @Sendable (String) -> String, uploading: Bool) async -> Int {
        if uploading {
            let doomed = deletions.map { (remotePath($0.relativePath), $0.isDirectory) }
            let failed = try? await queue.withOwnConnection(to: connection) { client in
                var failed = 0
                for (path, isDirectory) in doomed {
                    do { try await client.delete(at: path, isDirectory: isDirectory) } catch { failed += 1 }
                }
                return failed
            }
            return failed ?? deletions.count      // couldn't even connect
        }
        var failed = 0
        for deletion in deletions {
            do { try trash(localRoot.appending(path: deletion.relativePath)) } catch { failed += 1 }
        }
        return failed
    }
}
