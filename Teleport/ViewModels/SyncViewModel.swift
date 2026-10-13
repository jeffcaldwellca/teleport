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
        trash: @escaping (URL) throws -> Void = { try LocalFileService.shared.delete(at: $0) }
    ) {
        self.connection = connection
        self.localRoot = localRoot
        self.remoteRoot = remoteRoot
        self.queue = queue
        self.trash = trash
    }

    private var options: SyncOptions {
        SyncOptions(deleteExtraneous: deleteExtraneous, sizeOnly: sizeOnly)
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

    /// Carry out the reviewed plan: folders first, then the transfers go to
    /// the queue (as overwrites — the plan already decided), then deletions.
    func apply() async {
        guard phase == .ready, let plan else { return }
        phase = .applying
        let remoteRoot = remoteRoot
        let remotePath: @Sendable (String) -> String = { FolderSync.joined(remoteRoot, $0) }
        var failures: [String] = []

        do {
            switch plan.direction {
            case .upload:
                let folders = plan.directories.map { remotePath($0.relativePath) }
                let doomed = plan.deletions.map { (remotePath($0.relativePath), $0.isDirectory) }
                failures = try await queue.withOwnConnection(to: connection) { client in
                    // May exist already; a genuinely missing folder shows up
                    // as failed uploads in the queue.
                    try? await client.createDirectory(at: remoteRoot)
                    for folder in folders { try? await client.createDirectory(at: folder) }
                    var failed: [String] = []
                    for (path, isDirectory) in doomed {
                        do { try await client.delete(at: path, isDirectory: isDirectory) }
                        catch { failed.append(path) }
                    }
                    return failed
                }
            case .download:
                try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
                for folder in plan.directories {
                    try FileManager.default.createDirectory(at: localRoot.appending(path: folder.relativePath),
                                                            withIntermediateDirectories: true)
                }
                for deletion in plan.deletions {
                    let url = localRoot.appending(path: deletion.relativePath)
                    do { try trash(url) } catch { failures.append(deletion.relativePath) }
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        queue.enqueueBatch(
            connection: connection,
            direction: plan.direction == .upload ? .upload : .download,
            items: plan.transfers.map { (localRoot.appending(path: $0.relativePath), remotePath($0.relativePath)) },
            conflictBehavior: .overwrite
        )

        self.plan = nil
        phase = .done(Self.outcome(of: plan, failedDeletions: failures.count))
        onApplied?()
    }

    private static func outcome(of plan: SyncPlan, failedDeletions: Int) -> String {
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if !plan.transfers.isEmpty { parts.append("\(count(plan.transfers.count, "transfer")) queued") }
        let deleted = plan.deletions.count - failedDeletions
        if deleted > 0 { parts.append("\(count(deleted, "item")) deleted") }
        if failedDeletions > 0 { parts.append("\(count(failedDeletions, "item")) could not be deleted") }
        return parts.isEmpty ? "Nothing needed doing." : parts.joined(separator: ", ") + "."
    }
}
