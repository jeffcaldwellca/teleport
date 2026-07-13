import Foundation
import TeleportKit

enum TransferDirection {
    case upload
    case download
}

enum ConflictResolution {
    case overwrite
    case overwriteIfNewer
    case skip
    case autoRename
}

enum TransferStatus: Equatable {
    case queued
    case connecting
    case retrying(Int)   // attempt number (1-based)
    case active
    case completed
    case failed(String)
    case cancelled
    case skipped         // user (or policy) chose to skip a conflicting file
    case paused          // user paused; partial bytes are kept for resume

    /// Automatic retries after the first attempt. Single source of truth for
    /// the "(n/2)" labels in the UI.
    static let maxRetries = 2

    var isFinal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .skipped: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .queued:              return "Queued"
        case .connecting:          return "Connecting…"
        case .retrying(let n):     return "Retrying (\(n)/\(Self.maxRetries))…"
        case .active:              return "Transferring"
        case .completed:           return "Done"
        case .failed(let msg):     return "Failed: \(msg)"
        case .cancelled:           return "Cancelled"
        case .skipped:             return "Skipped"
        case .paused:              return "Paused"
        }
    }
}

@Observable
@MainActor
final class TransferTask: Identifiable {
    let id = UUID()
    let connection: Connection
    let direction: TransferDirection
    let localURL: URL
    let remotePath: String
    let fileName: String

    /// Effective destination — may differ from originals when auto-rename is chosen.
    var effectiveLocalURL: URL
    var effectiveRemotePath: String

    var status: TransferStatus = .queued

    /// Set by `pause()` before cancelling the in-flight transfer, so the
    /// cancellation handler lands the task in `.paused` instead of `.cancelled`.
    var pauseRequested = false

    /// Resume from partial bytes on the next (first) attempt — set when the
    /// user resumes a paused task, where attempt-0 would otherwise truncate.
    var resumeOnNextAttempt = false

    /// Predetermined conflict resolution (skips the dialog). Used by the
    /// remote-edit auto-upload, which must always overwrite its own file.
    var conflictBehavior: ConflictResolution? = nil

    var bytesTransferred: Int64 = 0
    var totalBytes: Int64 = 0
    var progress: Double = 0
    var throughput: Double = 0   // bytes/sec
    var retryCount: Int = 0

    private var lastSampleTime: Date?
    private var lastSampleBytes: Int64 = 0

    init(
        connection: Connection,
        direction: TransferDirection,
        localURL: URL,
        remotePath: String
    ) {
        self.connection = connection
        self.direction = direction
        self.localURL = localURL
        self.remotePath = remotePath
        self.fileName = localURL.lastPathComponent
        self.effectiveLocalURL = localURL
        self.effectiveRemotePath = remotePath
    }

    func start() {
        lastSampleTime = Date()
    }

    func updateProgress(bytes: Int64, total: Int64) {
        bytesTransferred = bytes
        totalBytes = total
        progress = total > 0 ? Double(bytes) / Double(total) : 0

        let now = Date()
        if let last = lastSampleTime, now.timeIntervalSince(last) >= 0.5 {
            let elapsed = now.timeIntervalSince(last)
            let delta = bytes - lastSampleBytes
            throughput = Double(delta) / elapsed
            lastSampleTime = now
            lastSampleBytes = bytes
        }
    }

    var displayThroughput: String {
        guard status == .active, throughput > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(throughput), countStyle: .file) + "/s"
    }

    var eta: String {
        guard status == .active, throughput > 0, totalBytes > bytesTransferred else { return "" }
        let remaining = Double(totalBytes - bytesTransferred) / throughput
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: remaining) ?? ""
    }
}
