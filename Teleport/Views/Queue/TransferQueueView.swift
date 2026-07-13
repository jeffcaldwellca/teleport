import SwiftUI

struct TransferQueueView: View {
    @Environment(AppState.self) private var appState

    private var queue: TransferQueueViewModel { appState.transferQueue }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ─────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: queue.hasActiveTasks ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                    .foregroundStyle(.secondary)
                Text("Transfers")
                    .font(.callout.weight(.medium))

                if queue.hasActiveTasks {
                    Text("\(queue.activeCount) active · \(queue.queuedCount) queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }

                Spacer(minLength: 8)

                if queue.failedCount > 0 {
                    Label("\(queue.failedCount) failed", systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(1)

                    Button("Retry Failed") { queue.retryAllFailed() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .help("Re-queue all failed transfers")
                }

                Button("Clear Completed") { queue.clearCompleted() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(queue.tasks.filter(\.status.isFinal).isEmpty)
                    .help("Remove completed, failed, and cancelled transfers")

                Button {
                    queue.setVisible(false)
                } label: {
                    Image(systemName: "xmark")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Close Transfers")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if queue.tasks.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No transfers")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(queue.tasks) { task in
                            TransferRowView(task: task)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
            }
        }
        .background(.background)
    }
}

// MARK: - TransferRowView

struct TransferRowView: View {
    @Bindable var task: TransferTask
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            // Direction icon
            Image(systemName: task.direction == .download ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(directionColor)
                .imageScale(.large)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                // File name + status
                HStack(spacing: 8) {
                    Text(task.fileName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    statusBadge
                }

                // Progress bar (or thin placeholder for non-active states so
                // the row keeps a stable height instead of jumping)
                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                    .tint(directionColor)
                    .frame(height: 4)
                    .opacity(showsProgressBar ? 1 : 0)

                // Stats
                HStack(spacing: 4) {
                    if task.totalBytes > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: task.bytesTransferred, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: task.totalBytes, countStyle: .file))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if !task.displayThroughput.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(task.displayThroughput)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if !task.eta.isEmpty {
                        Text("· ETA \(task.eta)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(task.connection.host)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            // Trailing action slot — always reserves space so rows don't jiggle
            // when a task transitions to a final state.
            HStack(spacing: 6) {
                if task.status == .paused {
                    Button { appState.transferQueue.resume(task) } label: {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.blue)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Resume")
                    .accessibilityLabel("Resume transfer")

                    Button { appState.transferQueue.cancel(task) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                    .accessibilityLabel("Cancel transfer")
                } else if !task.status.isFinal {
                    Button { appState.transferQueue.pause(task) } label: {
                        Image(systemName: "pause.circle")
                            .foregroundStyle(.secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Pause (keeps partial data for resume)")
                    .accessibilityLabel("Pause transfer")

                    Button { appState.transferQueue.cancel(task) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel")
                    .accessibilityLabel("Cancel transfer")
                } else if isFailed {
                    Button { appState.transferQueue.retry(task) } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .foregroundStyle(.blue)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Retry")
                    .accessibilityLabel("Retry transfer")
                } else if task.status == .completed, task.direction == .download {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([task.effectiveLocalURL])
                    } label: {
                        Image(systemName: "magnifyingglass.circle.fill")
                            .foregroundStyle(.secondary)
                            .imageScale(.large)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                    .accessibilityLabel("Show downloaded file in Finder")
                } else {
                    Color.clear
                }
            }
            .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var directionColor: Color {
        task.direction == .download ? .blue : .green
    }

    private var showsProgressBar: Bool {
        if case .active = task.status { return true }
        return false
    }

    private var isFailed: Bool {
        if case .failed = task.status { return true }
        return false
    }

    private var progressValue: Double {
        if case .active = task.status { return task.progress }
        return 0
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch task.status {
        case .queued:
            badge(text: "Queued", tint: .secondary)
        case .connecting:
            badge(text: "Connecting", tint: .blue, showsSpinner: true)
        case .retrying(let n):
            badge(text: "Retry \(n)/\(TransferStatus.maxRetries)", tint: .orange, showsSpinner: true)
        case .active:
            badge(text: String(format: "%.0f%%", task.progress * 100), tint: directionColor, monospaced: true)
        case .completed:
            badge(text: "Done", tint: .green, icon: "checkmark")
        case .failed:
            badge(text: "Failed", tint: .red, icon: "exclamationmark.triangle.fill")
        case .cancelled:
            badge(text: "Cancelled", tint: .secondary)
        case .skipped:
            badge(text: "Skipped", tint: .secondary)
        case .paused:
            badge(text: "Paused", tint: .orange, icon: "pause.fill")
        }
    }

    @ViewBuilder
    private func badge(text: String, tint: Color, showsSpinner: Bool = false, icon: String? = nil, monospaced: Bool = false) -> some View {
        HStack(spacing: 4) {
            if showsSpinner {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon).imageScale(.small)
            }
            Text(text)
                .font(monospaced ? .caption.monospacedDigit() : .caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
    }
}
