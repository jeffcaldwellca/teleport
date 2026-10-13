import Foundation
import TeleportKit
import SwiftUI

// MARK: - Conflict Info

/// Presented to the user when a transfer destination already exists.
struct ConflictInfo: Identifiable {
    let id: UUID          // matches the TransferTask.id that triggered the conflict
    let fileName: String
    let direction: TransferDirection
    let isDownload: Bool
    let localModifiedDate: Date?
    let remoteModifiedDate: Date?
}

// MARK: - Progress Throttle

/// Clients report progress once per chunk — thousands of times a second on a
/// fast link. Forward at most ~10 a second, plus always the final one, so the
/// main actor isn't flooded with updates the eye can't see anyway.
final class ProgressThrottle: @unchecked Sendable {
    private static let interval: TimeInterval = 0.1

    private let forward: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var lastForwarded = Date.distantPast

    init(_ forward: @escaping @Sendable (Int64, Int64) -> Void) {
        self.forward = forward
    }

    func callAsFunction(_ bytes: Int64, _ total: Int64) {
        let now = Date()
        let due = lock.withLock { () -> Bool in
            guard (total > 0 && bytes >= total) || now.timeIntervalSince(lastForwarded) >= Self.interval else {
                return false
            }
            lastForwarded = now
            return true
        }
        if due { forward(bytes, total) }
    }
}

// MARK: - TransferQueueViewModel

@Observable
@MainActor
final class TransferQueueViewModel {

    var tasks: [TransferTask] = []
    var isVisible = false

    /// Set when a task detects a file conflict and pauses for user input.
    var pendingConflict: ConflictInfo? = nil

    /// When set, all subsequent conflicts are resolved automatically without a dialog.
    var batchResolution: ConflictResolution? = nil

    private let passwordProvider: (Connection) -> String
    private let clientFactory: (Connection, String) -> RemoteClient
    private var conflictContinuation: CheckedContinuation<ConflictResolution, Never>?

    /// Number of running transfer workers. Bounded by `maxConcurrentTransfers`.
    private var workerCount = 0

    /// Index `claimNextQueued` resumes scanning from. Reset whenever an
    /// earlier task can become queued again or the array is rearranged.
    private var queuedSearchStart = 0

    /// The running transfer per task id, so `cancel` can interrupt an in-flight
    /// transfer (not just mark it). Cancelling the handle propagates into the
    /// client's read/write loop via `Task.isCancelled`.
    private var transferHandles: [UUID: Task<Void, Never>] = [:]

    /// Serializes the conflict dialog: there's a single `pendingConflict` slot,
    /// so concurrent transfers must take turns prompting the user.
    private var conflictGateBusy = false
    private var conflictGateWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter clientFactory: builds the client for each transfer; tests
    ///   substitute a scripted one.
    init(
        passwordProvider: @escaping (Connection) -> String,
        clientFactory: @escaping (Connection, String) -> RemoteClient = RemoteClientFactory.makeForTransfers(for:password:)
    ) {
        self.passwordProvider = passwordProvider
        self.clientFactory = clientFactory
    }

    // MARK: - Visibility

    /// Single funnel for showing/hiding the queue so the slide transition is
    /// always applied, no matter which control toggled it (toolbar, ⌘⇧Y, or an
    /// enqueue auto-show). Previously some paths animated and others popped.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        withAnimation(.spring(duration: 0.25)) { isVisible = visible }
    }

    func toggleVisible() {
        setVisible(!isVisible)
    }

    // MARK: - Enqueue

    /// Returns the created task, or nil when the enqueue was dropped as a
    /// duplicate of a still-pending transfer to the same destination.
    @discardableResult
    func enqueue(
        connection: Connection,
        direction: TransferDirection,
        localURL: URL,
        remotePath: String,
        conflictBehavior: ConflictResolution? = nil
    ) -> TransferTask? {
        // "Apply to all remaining conflicts" scopes to one batch: once every
        // prior task has finished, a fresh enqueue starts a new batch.
        if !tasks.contains(where: { !$0.status.isFinal }) {
            batchResolution = nil
        }

        // Refuse duplicates of a still-pending transfer to the same destination —
        // two workers writing the same local file interleave and corrupt it.
        let isDuplicate = tasks.contains {
            !$0.status.isFinal &&
            $0.direction == direction &&
            $0.effectiveLocalURL == localURL &&
            $0.effectiveRemotePath == remotePath
        }
        if isDuplicate {
            setVisible(true)
            return nil
        }

        let task = TransferTask(
            connection: connection,
            direction: direction,
            localURL: localURL,
            remotePath: remotePath
        )
        task.conflictBehavior = conflictBehavior
        tasks.append(task)
        setVisible(true)
        startWorkers()
        return task
    }

    /// `enqueue` for a whole folder's worth of files (folder transfers, sync).
    /// `conflictBehavior` applies to every one of them. Checks for duplicates
    /// against one precomputed set instead of rescanning the queue per file,
    /// which is quadratic and stalls the UI for thousands of items.
    /// Returns the tasks it created (duplicates of pending transfers are dropped).
    @discardableResult
    func enqueueBatch(
        connection: Connection,
        direction: TransferDirection,
        items: [(local: URL, remote: String)],
        conflictBehavior: ConflictResolution? = nil
    ) -> [TransferTask] {
        guard !items.isEmpty else { return [] }
        if !tasks.contains(where: { !$0.status.isFinal }) {
            batchResolution = nil
        }
        func key(_ local: URL, _ remote: String) -> String { "\(local.path)\u{0}\(remote)" }
        var pending = Set(
            tasks.lazy
                .filter { !$0.status.isFinal && $0.direction == direction }
                .map { key($0.effectiveLocalURL, $0.effectiveRemotePath) }
        )
        var created: [TransferTask] = []
        for item in items where pending.insert(key(item.local, item.remote)).inserted {
            let task = TransferTask(
                connection: connection, direction: direction,
                localURL: item.local, remotePath: item.remote
            )
            task.conflictBehavior = conflictBehavior
            tasks.append(task)
            created.append(task)
        }
        setVisible(true)
        startWorkers()
        return created
    }

    // MARK: - Queue Processing

    /// Spin up transfer workers up to the user's concurrency limit. Each worker
    /// pulls queued tasks until none remain, then exits.
    private func startWorkers() {
        let limit = max(1, Preferences.shared.maxConcurrentTransfers)
        while workerCount < limit, tasks.contains(where: { $0.status == .queued }) {
            workerCount += 1
            Task { await workerLoop() }
        }
    }

    /// What a run of transfers amounted to, reported when the queue drains.
    struct IdleSummary: Equatable {
        var completed: Int
        var failed: Int
    }

    /// Called each time the last worker finishes with nothing left queued.
    var onIdle: ((IdleSummary) -> Void)?

    /// Final tasks already counted in an earlier summary.
    private var summarizedTaskIDs: Set<UUID> = []

    /// Anything not yet finished, paused transfers included — quitting loses them.
    var hasUnfinishedTransfers: Bool { tasks.contains { !$0.status.isFinal } }

    /// Transfers still queued or running (the Dock badge).
    var remainingCount: Int {
        tasks.reduce(0) { $0 + (($1.status.isFinal || $1.status == .paused) ? 0 : 1) }
    }

    private func reportIdleIfDrained() {
        guard workerCount == 0, !tasks.contains(where: { $0.status == .queued }) else { return }
        var summary = IdleSummary(completed: 0, failed: 0)
        for task in tasks where task.status.isFinal && summarizedTaskIDs.insert(task.id).inserted {
            if task.status == .completed { summary.completed += 1 }
            if case .failed = task.status { summary.failed += 1 }
        }
        summarizedTaskIDs.formIntersection(Set(tasks.map(\.id)))
        if summary.completed + summary.failed > 0 { onIdle?(summary) }
    }

    private func workerLoop() async {
        defer {
            workerCount -= 1
            reportIdleIfDrained()
        }
        // The connection this worker keeps between tasks, so a run of files
        // for one server costs a single login instead of one per file.
        let kept = KeptConnection()
        while let task = claimNextQueued() {
            // Run the transfer in its own handle so `cancel(task)` can interrupt
            // just this transfer without killing the worker.
            let handle = Task { await processTask(task, kept: kept) }
            transferHandles[task.id] = handle
            await handle.value
            transferHandles.removeValue(forKey: task.id)
        }
        await kept.close()
    }

    /// A worker's idle connection, held between tasks.
    @MainActor
    private final class KeptConnection {
        private var connection: Connection?
        private var client: RemoteClient?

        func keep(_ client: RemoteClient, for connection: Connection) {
            self.client = client
            self.connection = connection
        }

        /// Hand back the kept client if it is for `connection` and still
        /// answers. The liveness check matters beyond saving a retry: the
        /// conflict check's `fileExists` reports a dead connection as "no
        /// such file", which would let an upload overwrite without asking.
        func take(for connection: Connection) async -> RemoteClient? {
            guard let client else { return nil }
            self.client = nil
            if self.connection == connection, (try? await client.ping()) != nil {
                return client
            }
            await client.disconnect()
            return nil
        }

        func close() async {
            await client?.disconnect()
            client = nil
        }
    }

    /// Atomically claim the next queued task. The read and the status write
    /// happen with no `await` in between on the MainActor, so two workers can
    /// never grab the same task.
    private func claimNextQueued() -> TransferTask? {
        // Everything before `queuedSearchStart` has already been claimed, so
        // a long queue isn't rescanned from the top for every task.
        let start = min(queuedSearchStart, tasks.count)
        guard let index = tasks[start...].firstIndex(where: { $0.status == .queued }) else {
            queuedSearchStart = tasks.count
            return nil
        }
        queuedSearchStart = index + 1
        let task = tasks[index]
        task.status = .connecting
        return task
    }

    private enum TransferOutcome {
        /// The task reached a terminal state (completed / failed / cancelled / paused).
        case finished
        /// Failed in a retryable way; the attempt has been counted and waited out.
        case retry
        /// Failed on a connection kept from an earlier task. That says nothing
        /// about this task, so run it again on a fresh connection without
        /// spending one of its retries.
        case redoOnFreshConnection
    }

    private func processTask(_ task: TransferTask, kept: KeptConnection) async {
        let maxRetries = TransferStatus.maxRetries
        var attempt = 0

        while attempt <= maxRetries {
            if Task.isCancelled || task.status == .cancelled {
                settleInterruption(task)
                return
            }

            // --- Connect (or pick up this worker's kept connection) ---
            task.status = attempt == 0 ? .connecting : .retrying(attempt)
            let password = passwordProvider(task.connection)
            let client: RemoteClient
            let reused: Bool
            if let keptClient = await kept.take(for: task.connection) {
                client = keptClient
                reused = true
            } else {
                client = clientFactory(task.connection, password)
                reused = false
                do {
                    try await client.connect()
                } catch {
                    await client.disconnect()
                    if error is CancellationError { settleInterruption(task); return }
                    if isFatal(error) || attempt >= maxRetries {
                        task.status = .failed(friendlyMessage(error))
                        return
                    }
                    try? await Task.sleep(for: .seconds(retryDelay(attempt: attempt + 1)))
                    attempt += 1
                    continue
                }
            }

            // Re-check after the connect round trip: the user may have hit
            // Cancel while we were connecting, and the conflict path below
            // must never open a dialog for a dead transfer.
            if Task.isCancelled || task.status == .cancelled {
                await client.disconnect()
                settleInterruption(task)
                return
            }

            // --- Conflict check ---
            // Once per task, on whichever attempt first gets a connection: a
            // retry's partial file must not re-trigger the dialog (or worse,
            // auto-rename mid-resume), and an attempt that died connecting
            // must not let the next one skip the question. The resolution
            // mutates `effective*` paths, which later attempts reuse.
            let hasConflict: Bool
            let localDate: Date?
            let remoteDate: Date?
            if !task.conflictSettled && !task.resumeOnNextAttempt {
                localDate  = localModifiedDate(for: task)
                remoteDate = await client.remoteModifiedDate(at: task.effectiveRemotePath)
                switch task.direction {
                case .download:
                    hasConflict = FileManager.default.fileExists(atPath: task.effectiveLocalURL.path)
                case .upload:
                    // Existence check, not MDTM: servers without MDTM (or files
                    // without an mtime) must still count as conflicts, otherwise
                    // the remote file is silently overwritten.
                    hasConflict = await client.fileExists(at: task.effectiveRemotePath)
                }
            } else {
                hasConflict = false
                localDate   = nil
                remoteDate  = nil
            }

            var transferClient = client
            var transferReused = reused
            if hasConflict && task.conflictBehavior != .overwrite {
                // Disconnect before waiting for user — server may time out the idle connection.
                await client.disconnect()

                let resolution = await askUserAboutConflict(
                    task: task,
                    localDate: localDate,
                    remoteDate: remoteDate
                )
                let effectiveResolution = resolve(
                    resolution,
                    task: task,
                    localDate: localDate,
                    remoteDate: remoteDate
                )
                switch effectiveResolution {
                case .skip:
                    // Preserve .cancelled if the user cancelled while the
                    // dialog was up; otherwise this is a deliberate skip.
                    task.status = task.status == .cancelled ? .cancelled : .skipped
                    return
                case .autoRename:
                    if task.direction == .download {
                        task.effectiveLocalURL = uniqueLocalURL(for: task.effectiveLocalURL)
                    } else {
                        // Picked in performTransfer, which has a live client.
                        task.needsUniqueRemotePath = true
                    }
                case .overwrite, .overwriteIfNewer:
                    break
                }
                task.conflictSettled = true

                // Reconnect with the (possibly new) effective path
                task.status = attempt == 0 ? .connecting : .retrying(attempt)
                let freshClient = clientFactory(task.connection, password)
                do {
                    try await freshClient.connect()
                } catch {
                    await freshClient.disconnect()
                    if error is CancellationError { settleInterruption(task); return }
                    if isFatal(error) || attempt >= maxRetries {
                        task.status = .failed(friendlyMessage(error))
                        return
                    }
                    try? await Task.sleep(for: .seconds(retryDelay(attempt: attempt + 1)))
                    attempt += 1
                    continue
                }
                transferClient = freshClient
                transferReused = false
            }
            // No conflict, or a predetermined overwrite (remote-edit
            // auto-uploads) that needs no dialog: transfer on the live connection.
            task.conflictSettled = true

            // --- Transfer ---
            let outcome = await performTransfer(
                task: task, client: transferClient, reused: transferReused, kept: kept,
                attempt: attempt, maxRetries: maxRetries
            )
            switch outcome {
            case .finished:              return
            case .retry:                 attempt += 1
            case .redoOnFreshConnection: break
            }
        }
    }

    /// Run the transfer and say what the caller's attempt loop should do next.
    /// On success the connection goes back to the worker for its next task.
    private func performTransfer(
        task: TransferTask,
        client: RemoteClient,
        reused: Bool,
        kept: KeptConnection,
        attempt: Int,
        maxRetries: Int
    ) async -> TransferOutcome {
        task.status = .active
        task.start()

        // An auto-renamed upload picks its free remote name now that there is
        // a live connection to ask.
        if task.needsUniqueRemotePath {
            task.effectiveRemotePath = await uniqueRemotePath(for: task.effectiveRemotePath, using: client)
            task.needsUniqueRemotePath = false
        }

        // Resume only from bytes this task wrote itself (an earlier attempt,
        // or before the user paused). An attempt that never got as far as
        // transferring has left nothing to resume — whatever sits at the
        // destination is someone else's file.
        let resume = task.transferStarted || task.resumeOnNextAttempt
        task.transferStarted = true

        do {
            // A stall watchdog cancels the transfer if no progress is made for
            // a while (covers SFTP, which lacks FTP's socket-level read
            // timeout) — surfacing as a retry.
            let report = ProgressThrottle { bytes, total in
                Task { @MainActor in task.updateProgress(bytes: bytes, total: total) }
            }
            try await runWithStallWatchdog(task: task) {
                switch task.direction {
                case .download:
                    try await client.download(
                        remotePath: task.effectiveRemotePath,
                        to: task.effectiveLocalURL,
                        resume: resume,
                        progress: report.callAsFunction
                    )
                case .upload:
                    try await client.upload(
                        from: task.effectiveLocalURL,
                        remotePath: task.effectiveRemotePath,
                        resume: resume,
                        progress: report.callAsFunction
                    )
                }
            }
            // Preserve modification times so "overwrite if newer" stays
            // truthful: without this, every download looks newer than the
            // server copy (its mtime is the download moment), and every
            // subsequent conflict resolves the wrong way.
            switch task.direction {
            case .download:
                if let remote = await client.remoteModifiedDate(at: task.effectiveRemotePath) {
                    try? FileManager.default.setAttributes(
                        [.modificationDate: remote],
                        ofItemAtPath: task.effectiveLocalURL.path
                    )
                }
            case .upload:
                if let local = localModifiedDate(for: task) {
                    await client.setModifiedDate(local, at: task.effectiveRemotePath)
                }
            }
            kept.keep(client, for: task.connection)
            task.status = .completed
            task.progress = 1.0
            NotificationCenter.default.post(
                name: .transferCompleted,
                object: nil,
                userInfo: ["direction": task.direction == .download ? "download" : "upload",
                           "connectionID": task.connection.id]
            )
            return .finished
        } catch {
            await client.disconnect()
            // User cancellation or pause: stop immediately, don't retry.
            if error is CancellationError {
                settleInterruption(task)
                return .finished
            }
            if isFatal(error) {
                task.status = .failed(friendlyMessage(error))
                return .finished
            }
            if reused { return .redoOnFreshConnection }
            if attempt >= maxRetries {
                task.status = .failed(friendlyMessage(error))
                return .finished
            }
            task.status = .retrying(attempt + 1)
            task.retryCount = attempt + 1
            try? await Task.sleep(for: .seconds(retryDelay(attempt: attempt + 1)))
            return .retry
        }
    }

    // MARK: - Stall Watchdog

    /// Seconds without any byte progress before a transfer is considered stalled.
    private static let stallTimeout: TimeInterval = 60

    /// Run `transfer` alongside a watchdog that cancels it if `bytesTransferred`
    /// stops advancing for `stallTimeout`. The cancellation surfaces as a
    /// (retryable) error to the caller.
    private func runWithStallWatchdog(
        task: TransferTask,
        _ transfer: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await transfer() }
            group.addTask { [weak self] in try await self?.stallWatchdog(task: task) }
            defer { group.cancelAll() }
            try await group.next()   // first to finish/throw wins
        }
    }

    private func stallWatchdog(task: TransferTask) async throws {
        let tick: TimeInterval = 5
        var lastBytes: Int64 = -1
        var stalled: TimeInterval = 0
        while true {
            try await Task.sleep(for: .seconds(tick))
            if task.bytesTransferred != lastBytes {
                lastBytes = task.bytesTransferred
                stalled = 0
            } else {
                stalled += tick
                if stalled >= Self.stallTimeout {
                    throw RemoteClientError.transferFailed(
                        "No progress for \(Int(Self.stallTimeout))s — connection stalled"
                    )
                }
            }
        }
    }

    // MARK: - Conflict Resolution

    private func askUserAboutConflict(task: TransferTask, localDate: Date?, remoteDate: Date?) async -> ConflictResolution {
        // An already-cancelled task must not reach the dialog: with the task
        // pre-cancelled, withTaskCancellationHandler fires onCancel BEFORE the
        // continuation is stored, so the skip would be a no-op and the dialog
        // would appear orphaned — permanently holding the conflict gate.
        if Task.isCancelled || task.status == .cancelled { return .skip }

        // Honour a previously chosen batch resolution without showing a dialog.
        if let batch = batchResolution { return batch }

        // Honour the user's persisted "default action" preference, if any.
        switch Preferences.shared.defaultConflict {
        case .overwrite:        return .overwrite
        case .overwriteIfNewer: return .overwriteIfNewer
        case .autoRename:       return .autoRename
        case .skip:             return .skip
        case .ask:              break  // fall through to the prompt
        }

        // Only one dialog at a time — concurrent transfers queue here.
        await acquireConflictGate()
        defer { releaseConflictGate() }
        // A dialog we waited behind may have set an "apply to all" resolution.
        if let batch = batchResolution { return batch }

        let info = ConflictInfo(
            id: task.id,
            fileName: task.fileName,
            direction: task.direction,
            isDownload: task.direction == .download,
            localModifiedDate: localDate,
            remoteModifiedDate: remoteDate
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                self.conflictContinuation = cont
                self.pendingConflict = info
            }
        } onCancel: {
            Task { @MainActor in self.resolveConflictInternal(.skip) }
        }
    }

    /// Wait until no other transfer is showing a conflict dialog.
    private func acquireConflictGate() async {
        while conflictGateBusy {
            await withCheckedContinuation { conflictGateWaiters.append($0) }
        }
        conflictGateBusy = true
    }

    private func releaseConflictGate() {
        conflictGateBusy = false
        if !conflictGateWaiters.isEmpty {
            conflictGateWaiters.removeFirst().resume()
        }
    }

    /// Translates `.overwriteIfNewer` into a concrete action using the available dates.
    private func resolve(
        _ resolution: ConflictResolution,
        task: TransferTask,
        localDate: Date?,
        remoteDate: Date?
    ) -> ConflictResolution {
        guard case .overwriteIfNewer = resolution else { return resolution }
        switch task.direction {
        case .download:
            // Overwrite local if remote is strictly newer
            if let remote = remoteDate, let local = localDate, remote > local { return .overwrite }
            return .skip
        case .upload:
            // Overwrite remote if local is strictly newer
            if let local = localDate, let remote = remoteDate, local > remote { return .overwrite }
            return .skip
        }
    }

    func resolveConflict(_ resolution: ConflictResolution, applyToAll: Bool) {
        if applyToAll { batchResolution = resolution }
        pendingConflict = nil
        conflictContinuation?.resume(returning: resolution)
        conflictContinuation = nil
    }

    // Convenience overload used by cancellation handler
    private func resolveConflictInternal(_ resolution: ConflictResolution) {
        pendingConflict = nil
        conflictContinuation?.resume(returning: resolution)
        conflictContinuation = nil
    }

    // MARK: - Controls

    /// Route a CancellationError (or a pre-flight cancelled check) to the right
    /// terminal-ish state: `.paused` when the interruption was a pause request,
    /// `.cancelled` otherwise.
    private func settleInterruption(_ task: TransferTask) {
        if task.pauseRequested {
            task.pauseRequested = false
            task.status = .paused
        } else {
            task.status = .cancelled
            discardPartial(task)
        }
    }

    /// A download nobody will resume shouldn't leave its staged ".part" file
    /// behind. Paused and failed downloads keep theirs for resume / retry.
    private func discardPartial(_ task: TransferTask) {
        guard task.direction == .download else { return }
        DownloadStaging.discardPartial(for: task.effectiveLocalURL)
    }

    /// Pause a queued or in-flight transfer, keeping partial bytes for resume.
    func pause(_ task: TransferTask) {
        switch task.status {
        case .queued:
            task.status = .paused        // not started — nothing to interrupt
        case .connecting, .retrying, .active:
            task.pauseRequested = true
            transferHandles[task.id]?.cancel()
        default:
            break                        // final or already paused
        }
    }

    /// Resume a paused transfer from its partial bytes.
    func resume(_ task: TransferTask) {
        guard task.status == .paused else { return }
        task.pauseRequested = false
        task.resumeOnNextAttempt = true  // attempt 0 must append, not truncate
        task.status = .queued
        queuedSearchStart = 0
        startWorkers()
    }

    func cancel(_ task: TransferTask) {
        // If waiting on conflict for this task, dismiss and skip it.
        if pendingConflict?.id == task.id {
            resolveConflictInternal(.skip)
        }
        // An in-flight transfer drops its partial file once it has actually
        // stopped (settleInterruption); a parked one has nothing running.
        if let handle = transferHandles[task.id] {
            handle.cancel()
        } else if !task.status.isFinal {
            discardPartial(task)
        }
        task.status = .cancelled
    }

    func cancelAll() {
        if pendingConflict != nil { resolveConflictInternal(.skip) }
        transferHandles.values.forEach { $0.cancel() }
        for task in tasks where !task.status.isFinal {
            if transferHandles[task.id] == nil { discardPartial(task) }
            task.status = .cancelled
        }
        batchResolution = nil
    }

    func clearCompleted() {
        // A failed download kept its partial file for Retry; clearing the row
        // gives that up.
        for task in tasks {
            if case .failed = task.status { discardPartial(task) }
        }
        tasks.removeAll { $0.status.isFinal }
        queuedSearchStart = 0
    }

    /// Re-queue a single failed transfer from the start.
    func retry(_ task: TransferTask) {
        guard case .failed = task.status else { return }
        resetForRetry(task)
        startWorkers()
    }

    /// Re-queue every failed transfer.
    func retryAllFailed() {
        var requeued = false
        for task in tasks {
            if case .failed = task.status {
                resetForRetry(task)
                requeued = true
            }
        }
        if requeued { startWorkers() }
    }

    private func resetForRetry(_ task: TransferTask) {
        task.retryCount          = 0
        task.bytesTransferred    = 0
        task.progress            = 0
        task.pauseRequested      = false
        task.transferStarted     = false
        // A failed download kept its staged bytes — continue from them. The
        // conflict was already settled on the first run.
        task.resumeOnNextAttempt = task.direction == .download
        task.status              = .queued
        queuedSearchStart        = 0
    }

    func removeAll() {
        cancelAll()
        tasks.removeAll()
        queuedSearchStart = 0
    }

    // MARK: - Stats

    var activeCount: Int  { tasks.filter { $0.status == .active }.count }
    var queuedCount: Int  { tasks.filter { $0.status == .queued }.count }
    var failedCount: Int  { tasks.filter { if case .failed = $0.status { return true }; return false }.count }
    var hasActiveTasks: Bool { activeCount + queuedCount > 0 }

    // MARK: - Helpers

    private func isFatal(_ error: Error) -> Bool {
        if let e = error as? RemoteClientError {
            switch e {
            case .authenticationFailed, .authenticationRejected, .permissionDenied,
                 .hostKeyUntrusted, .hostKeyMismatch:
                return true
            default: return false
            }
        }
        if let e = error as? FTPError {
            switch e {
            case .authFailed, .permissionDenied, .untrustedCertificate, .certificateChanged: return true
            default: return false
            }
        }
        return false
    }

    private func friendlyMessage(_ error: Error) -> String {
        if let e = error as? FTPError, case .permissionDenied = e {
            return "Permission denied — verify your server account permissions"
        }
        if let e = error as? RemoteClientError {
            switch e {
            case .permissionDenied:       return "Permission denied — verify your server account permissions"
            case .authenticationFailed:   return "Authentication failed — check your credentials"
            default: break
            }
        }
        return error.localizedDescription
    }

    private func retryDelay(attempt: Int) -> Double {
        pow(2.0, Double(attempt))   // 2s, 4s
    }

    func uniqueLocalURL(for url: URL) -> URL {
        var result = url
        var counter = 2
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        while FileManager.default.fileExists(atPath: result.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            result = dir.appending(component: name)
            counter += 1
        }
        return result
    }

    func uniqueRemotePath(for path: String, using client: RemoteClient) async -> String {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let sep = dir.hasSuffix("/") ? "" : "/"

        var counter = 2
        // Cap iterations defensively — a misconfigured server that always
        // reports "exists" must not trap us in an infinite loop.
        while counter < 1000 {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = "\(dir)\(sep)\(name)"
            if await !client.fileExists(at: candidate) { return candidate }
            counter += 1
        }
        // Fall back to a UUID suffix rather than overwriting.
        let unique = UUID().uuidString.prefix(8)
        let name = ext.isEmpty ? "\(base)-\(unique)" : "\(base)-\(unique).\(ext)"
        return "\(dir)\(sep)\(name)"
    }

    private func localModifiedDate(for task: TransferTask) -> Date? {
        let url = task.direction == .download ? task.effectiveLocalURL : task.localURL
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Tracked External Transfers

    /// Run an ad-hoc transfer (Quick Look temp download, drag-to-Finder export,
    /// remote-edit fetch) as a visible queue row with live progress and a
    /// working Cancel button — previously these ran invisibly with no way to
    /// stop them. `operation` receives a progress callback to forward to the
    /// client. Throws whatever the operation throws (CancellationError when
    /// the user cancels via the row).
    func runTracked(
        connection: Connection,
        direction: TransferDirection,
        localURL: URL,
        remotePath: String,
        _ operation: @escaping @Sendable (_ progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void
    ) async throws {
        let task = TransferTask(
            connection: connection,
            direction: direction,
            localURL: localURL,
            remotePath: remotePath
        )
        tasks.append(task)
        setVisible(true)
        task.status = .active
        task.start()

        final class ErrorBox: @unchecked Sendable { var error: Error? }
        let box = ErrorBox()
        let handle = Task {
            do {
                let report = ProgressThrottle { bytes, total in
                    Task { @MainActor in task.updateProgress(bytes: bytes, total: total) }
                }
                try await operation(report.callAsFunction)
            } catch {
                box.error = error
            }
        }
        transferHandles[task.id] = handle
        await handle.value
        transferHandles.removeValue(forKey: task.id)

        if let error = box.error {
            if error is CancellationError || task.status == .cancelled {
                task.status = .cancelled
            } else {
                task.status = .failed(friendlyMessage(error))
            }
            throw error
        }
        task.status = .completed
        task.progress = 1.0
        NotificationCenter.default.post(
            name: .transferCompleted,
            object: nil,
            userInfo: ["direction": direction == .download ? "download" : "upload",
                       "connectionID": connection.id]
        )
    }

    // MARK: - Folder Transfers

    /// Safety cap on entries a single recursive folder transfer may touch, so a
    /// runaway tree (or a malicious server with a cyclic listing) can't enqueue
    /// unbounded work.
    nonisolated static let folderTransferLimit = 10_000

    enum FolderTransferError: LocalizedError {
        case tooLarge
        case unreadable(String)
        case unsafeName(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge:
                return "Folder contains more than \(TransferQueueViewModel.folderTransferLimit) items. Transfer it in smaller pieces."
            case .unreadable(let name):
                return "Could not read the contents of \(name)."
            case .unsafeName(let name):
                return "'\(name)' contains characters that aren't allowed."
            }
        }
    }

    /// Recursively upload `folderURL` into `remoteParent`: creates the remote
    /// directory tree up front (uploads need existing parents), then enqueues
    /// one task per file. Symlinks are skipped — following them risks cycles
    /// and surprising escapes from the dragged tree.
    func enqueueFolderUpload(
        connection: Connection,
        folderURL: URL,
        remoteParent: String
    ) async throws {
        guard let folderName = RemotePath.sanitizedFilename(folderURL.lastPathComponent) else {
            throw FolderTransferError.unsafeName(folderURL.lastPathComponent)
        }

        // Off the main actor: enumerating a big tree takes long enough to
        // freeze the UI.
        let (relativeDirs, files) = try await Task.detached {
            try Self.walkLocalTree(at: folderURL)
        }.value

        let sep  = remoteParent.hasSuffix("/") ? "" : "/"
        let root = "\(remoteParent)\(sep)\(folderName)"

        // Parents sort before children ("a" < "a/b"), so creation order is safe.
        // Failures are tolerated here (the directory may already exist); a
        // genuinely missing parent surfaces as a visible failed upload below.
        try await withOwnConnection(to: connection) { client in
            try? await client.createDirectory(at: root)
            for dir in relativeDirs.sorted() {
                try? await client.createDirectory(at: "\(root)/\(dir)")
            }
        }
        enqueueBatch(connection: connection, direction: .upload,
                     items: files.map { ($0.local, "\(root)/\($0.relative)") })
    }

    /// Run `body` on a connection opened just for it and closed afterwards.
    ///
    /// For work that has to outlive the browsing tab it was started from: a
    /// folder transfer's preparation (making the remote folders, walking the
    /// remote tree) and drags out to Finder. Borrowing the session's own
    /// connection would break them the moment that tab is closed.
    func withOwnConnection<T: Sendable>(
        to connection: Connection,
        _ body: @Sendable (RemoteClient) async throws -> T
    ) async throws -> T {
        let client = clientFactory(connection, passwordProvider(connection))
        do {
            try await client.connect()
            let result = try await body(client)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// Synchronous local tree walk (directory enumeration isn't async-safe).
    /// Returns remote-relative directory paths and the files to upload.
    /// Symlinks are skipped — following them risks cycles and surprising
    /// escapes from the dragged tree.
    private nonisolated static func walkLocalTree(
        at folderURL: URL
    ) throws -> (dirs: [String], files: [(local: URL, relative: String)]) {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw FolderTransferError.unreadable(folderURL.lastPathComponent)
        }

        var dirs:  [String] = []
        var files: [(local: URL, relative: String)] = []
        let baseCount = folderURL.standardizedFileURL.pathComponents.count

        for case let url as URL in enumerator {
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if vals?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let components = url.standardizedFileURL.pathComponents.dropFirst(baseCount)
            guard !components.isEmpty,
                  components.allSatisfy({ RemotePath.sanitizedFilename($0) != nil }) else { continue }
            let relative = components.joined(separator: "/")
            if vals?.isDirectory == true {
                dirs.append(relative)
            } else {
                files.append((url, relative))
            }
            if dirs.count + files.count > folderTransferLimit {
                throw FolderTransferError.tooLarge
            }
        }
        return (dirs, files)
    }

    /// Recursively download the remote folder at `remotePath` into
    /// `localParent`: walks the remote tree breadth-first, creates local
    /// directories as it goes, and enqueues one task per file.
    func enqueueFolderDownload(
        connection: Connection,
        remotePath: String,
        folderName: String,
        into localParent: URL
    ) async throws {
        guard let safeName = RemotePath.sanitizedFilename(folderName) else {
            throw FolderTransferError.unsafeName(folderName)
        }

        let root = localParent.appending(component: safeName)
        let files = try await withOwnConnection(to: connection) { client in
            let fm = FileManager.default
            var pendingDirs: [(remote: String, local: URL)] = [(remotePath, root)]
            var files: [(remote: String, local: URL)] = []
            while let (remoteDir, localDir) = pendingDirs.popLast() {
                try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
                for item in try await client.listDirectory(at: remoteDir) {
                    // Names are already sanitized by the listing layer, but a local
                    // containment check keeps a hostile server from escaping the
                    // chosen destination (defence in depth).
                    guard let name = RemotePath.sanitizedFilename(item.name) else { continue }
                    let childLocal = localDir.appending(component: name)
                    guard RemotePath.isContained(childLocal, in: localDir) else { continue }
                    if item.isSymlink { continue }

                    if item.isDirectory {
                        pendingDirs.append((item.path, childLocal))
                    } else {
                        files.append((item.path, childLocal))
                    }
                    if files.count + pendingDirs.count > Self.folderTransferLimit {
                        throw FolderTransferError.tooLarge
                    }
                }
            }
            return files
        }

        enqueueBatch(connection: connection, direction: .download,
                     items: files.map { ($0.local, $0.remote) })
    }
}
