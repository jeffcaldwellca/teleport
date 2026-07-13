import Foundation
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
    private var conflictContinuation: CheckedContinuation<ConflictResolution, Never>?

    /// Number of running transfer workers. Bounded by `maxConcurrentTransfers`.
    private var workerCount = 0

    /// The running transfer per task id, so `cancel` can interrupt an in-flight
    /// transfer (not just mark it). Cancelling the handle propagates into the
    /// client's read/write loop via `Task.isCancelled`.
    private var transferHandles: [UUID: Task<Void, Never>] = [:]

    /// Serializes the conflict dialog: there's a single `pendingConflict` slot,
    /// so concurrent transfers must take turns prompting the user.
    private var conflictGateBusy = false
    private var conflictGateWaiters: [CheckedContinuation<Void, Never>] = []

    init(passwordProvider: @escaping (Connection) -> String) {
        self.passwordProvider = passwordProvider
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

    private func workerLoop() async {
        defer { workerCount -= 1 }
        while let task = claimNextQueued() {
            // Run the transfer in its own handle so `cancel(task)` can interrupt
            // just this transfer without killing the worker.
            let handle = Task { await processTask(task) }
            transferHandles[task.id] = handle
            await handle.value
            transferHandles.removeValue(forKey: task.id)
        }
    }

    /// Atomically claim the next queued task. The read and the status write
    /// happen with no `await` in between on the MainActor, so two workers can
    /// never grab the same task.
    private func claimNextQueued() -> TransferTask? {
        guard let task = tasks.first(where: { $0.status == .queued }) else { return nil }
        task.status = .connecting
        return task
    }

    private func processTask(_ task: TransferTask) async {
        let maxRetries = TransferStatus.maxRetries

        for attempt in 0...maxRetries {
            if Task.isCancelled || task.status == .cancelled {
                settleInterruption(task)
                return
            }

            // --- Connect ---
            task.status = attempt == 0 ? .connecting : .retrying(attempt)
            let password = passwordProvider(task.connection)
            let client = RemoteClientFactory.make(for: task.connection, password: password)

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
                continue
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
            // Only on the first attempt: a retry's partial file must not
            // re-trigger the dialog (or worse, auto-rename mid-resume). The
            // attempt-0 resolution already mutated `effective*` paths, which
            // retries reuse.
            let hasConflict: Bool
            let localDate: Date?
            let remoteDate: Date?
            if attempt == 0 && !task.resumeOnNextAttempt {
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

            if hasConflict {
                // A predetermined overwrite (remote-edit auto-uploads) needs no
                // dialog — keep the live connection and transfer right away.
                if task.conflictBehavior == .overwrite {
                    let shouldRetry = await performTransfer(
                        task: task, client: client,
                        attempt: attempt, maxRetries: maxRetries
                    )
                    if shouldRetry { continue }
                    return
                }

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
                    }
                    // Remote auto-rename happens after we reconnect (needs a live client).
                case .overwrite, .overwriteIfNewer:
                    break
                }

                // Reconnect with the (possibly new) effective path
                task.status = attempt == 0 ? .connecting : .retrying(attempt)
                let freshClient = RemoteClientFactory.make(for: task.connection, password: password)
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
                    continue
                }

                // For uploads with auto-rename, find the first non-existing path now that
                // we have a live connection.
                if effectiveResolution == .autoRename, task.direction == .upload {
                    task.effectiveRemotePath = await uniqueRemotePath(
                        for: task.effectiveRemotePath, using: freshClient
                    )
                }
                let shouldRetry = await performTransfer(
                    task: task, client: freshClient,
                    attempt: attempt, maxRetries: maxRetries
                )
                if shouldRetry { continue }
                return
            }

            // --- Transfer ---
            let shouldRetry = await performTransfer(
                task: task, client: client,
                attempt: attempt, maxRetries: maxRetries
            )
            if shouldRetry { continue }
            return
        }
    }

    /// Run the transfer, returning `true` if the caller's outer attempt loop
    /// should keep iterating to retry, `false` once the task is in a terminal
    /// state (completed / failed / cancelled).
    private func performTransfer(
        task: TransferTask,
        client: RemoteClient,
        attempt: Int,
        maxRetries: Int
    ) async -> Bool {
        task.status = .active
        task.start()

        do {
            // Retries resume from partial bytes, as does a task the user
            // un-paused. A stall watchdog cancels the transfer if no progress
            // is made for a while (covers SFTP, which lacks FTP's socket-level
            // read timeout) — surfacing as a retry.
            let resume = attempt > 0 || task.resumeOnNextAttempt
            try await runWithStallWatchdog(task: task) {
                switch task.direction {
                case .download:
                    try await client.download(
                        remotePath: task.effectiveRemotePath,
                        to: task.effectiveLocalURL,
                        resume: resume
                    ) { bytes, total in
                        Task { @MainActor in task.updateProgress(bytes: bytes, total: total) }
                    }
                case .upload:
                    try await client.upload(
                        from: task.effectiveLocalURL,
                        remotePath: task.effectiveRemotePath,
                        resume: resume
                    ) { bytes, total in
                        Task { @MainActor in task.updateProgress(bytes: bytes, total: total) }
                    }
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
            await client.disconnect()
            task.status = .completed
            task.progress = 1.0
            NotificationCenter.default.post(
                name: .transferCompleted,
                object: nil,
                userInfo: ["direction": task.direction == .download ? "download" : "upload"]
            )
            return false
        } catch {
            await client.disconnect()
            // User cancellation or pause: stop immediately, don't retry.
            if error is CancellationError {
                settleInterruption(task)
                return false
            }
            if isFatal(error) || attempt >= maxRetries {
                task.status = .failed(friendlyMessage(error))
                return false
            }
            task.status = .retrying(attempt + 1)
            task.retryCount = attempt + 1
            try? await Task.sleep(for: .seconds(retryDelay(attempt: attempt + 1)))
            // Tell the outer loop to retry — staying within this `for attempt`
            // iteration so the attempt counter actually advances. Previously
            // we set status back to `.queued` and returned, which caused
            // processQueue to re-pick the same task and restart attempt at 0.
            return true
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
        }
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
        startWorkers()
    }

    func cancel(_ task: TransferTask) {
        // If waiting on conflict for this task, dismiss and skip it.
        if pendingConflict?.id == task.id {
            resolveConflictInternal(.skip)
        }
        transferHandles[task.id]?.cancel()   // interrupt an in-flight transfer
        task.status = .cancelled
    }

    func cancelAll() {
        if pendingConflict != nil { resolveConflictInternal(.skip) }
        transferHandles.values.forEach { $0.cancel() }
        tasks.filter { !$0.status.isFinal }.forEach { $0.status = .cancelled }
        batchResolution = nil
    }

    func clearCompleted() {
        tasks.removeAll { $0.status.isFinal }
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
        task.resumeOnNextAttempt = false
        task.status              = .queued
    }

    func removeAll() {
        cancelAll()
        tasks.removeAll()
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
            case .authenticationFailed, .permissionDenied: return true
            default: return false
            }
        }
        if let e = error as? FTPError {
            switch e {
            case .authFailed, .permissionDenied: return true
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
                try await operation { bytes, total in
                    Task { @MainActor in task.updateProgress(bytes: bytes, total: total) }
                }
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
            userInfo: ["direction": direction == .download ? "download" : "upload"]
        )
    }

    // MARK: - Folder Transfers

    /// Safety cap on entries a single recursive folder transfer may touch, so a
    /// runaway tree (or a malicious server with a cyclic listing) can't enqueue
    /// unbounded work.
    nonisolated static let folderTransferLimit = 2000

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
        client: RemoteClient,
        folderURL: URL,
        remoteParent: String
    ) async throws {
        guard let folderName = RemotePath.sanitizedFilename(folderURL.lastPathComponent) else {
            throw FolderTransferError.unsafeName(folderURL.lastPathComponent)
        }

        let (relativeDirs, files) = try Self.walkLocalTree(at: folderURL)

        let sep  = remoteParent.hasSuffix("/") ? "" : "/"
        let root = "\(remoteParent)\(sep)\(folderName)"

        // Parents sort before children ("a" < "a/b"), so creation order is safe.
        // Failures are tolerated here (the directory may already exist); a
        // genuinely missing parent surfaces as a visible failed upload below.
        try? await client.createDirectory(at: root)
        for dir in relativeDirs.sorted() {
            try? await client.createDirectory(at: "\(root)/\(dir)")
        }
        for (local, relative) in files {
            enqueue(connection: connection, direction: .upload,
                    localURL: local, remotePath: "\(root)/\(relative)")
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
        client: RemoteClient,
        remotePath: String,
        folderName: String,
        into localParent: URL
    ) async throws {
        guard let safeName = RemotePath.sanitizedFilename(folderName) else {
            throw FolderTransferError.unsafeName(folderName)
        }

        let fm = FileManager.default
        var pendingDirs: [(remote: String, local: URL)] = [(remotePath, localParent.appending(component: safeName))]
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

        for (remote, local) in files {
            enqueue(connection: connection, direction: .download,
                    localURL: local, remotePath: remote)
        }
    }
}
