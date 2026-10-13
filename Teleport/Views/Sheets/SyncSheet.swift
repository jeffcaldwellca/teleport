import SwiftUI
import TeleportKit

/// Compare the local pane's folder with the session's folder, review what
/// syncing would do, then do it.
struct SyncSheet: View {
    @Bindable var model: SyncViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeletions = false

    private var isBusy: Bool { model.phase == .comparing || model.phase == .applying }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync Folders").font(.headline)

            endpoints

            Picker("Direction", selection: $model.direction) {
                Text("Upload to server").tag(SyncDirection.upload)
                Text("Download to this Mac").tag(SyncDirection.download)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isBusy)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(model.direction == .upload
                       ? "Delete files on the server that aren\u{2019}t in the local folder"
                       : "Move local files that aren\u{2019}t on the server to the Trash",
                       isOn: $model.deleteExtraneous)
                Toggle("Compare sizes only (ignore modification times)", isOn: $model.sizeOnly)
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            .disabled(isBusy)

            HStack(spacing: 8) {
                Text("Skip")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("node_modules, *.log, build/cache", text: $model.excludeText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit { Task { await model.compare() } }
                    .help("Names or patterns to leave out on both sides, separated by commas. Skipped items are never deleted either.")
            }
            .disabled(isBusy)

            results
                .frame(minHeight: 200, maxHeight: 320)

            HStack {
                if isBusy { ProgressView().controlSize(.small) }
                Text(statusLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if model.isWaitingToDelete {
                    Button("Don\u{2019}t Delete") { model.skipDeletions() }
                        .help("Let the transfers finish, but leave everything else at the destination in place")
                }
                // Closing while a sync is under way doesn't stop it.
                Button(isDone || model.phase == .applying ? "Close" : "Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !isDone && model.phase != .applying {
                    Button("Compare") { Task { await model.compare() } }
                        .disabled(isBusy)
                    Button("Sync") { startSync() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.phase != .ready || model.plan?.hasChanges != true)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await model.compare() }
        .confirmationDialog(
            deletionQuestion,
            isPresented: $confirmingDeletions,
            titleVisibility: .visible
        ) {
            Button(model.direction == .upload ? "Sync and Delete" : "Sync and Move to Trash", role: .destructive) {
                Task { await model.apply() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.direction == .upload
                 ? "Files deleted from the server can\u{2019}t be recovered."
                 : "You can restore them from the Trash.")
        }
    }

    // MARK: - Pieces

    private var endpoints: some View {
        let local = Label(model.localRoot.path, systemImage: "laptopcomputer")
        let remote = Label("\(model.connection.displayTitle):\(model.remoteRoot)",
                           systemImage: model.connection.connectionProtocol.systemImage)
        return HStack(spacing: 8) {
            if model.direction == .upload { local } else { remote }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            if model.direction == .upload { remote } else { local }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    @ViewBuilder
    private var results: some View {
        if let plan = model.plan, !plan.actions.isEmpty {
            List(Array(plan.actions.enumerated()), id: \.offset) { _, action in
                HStack(spacing: 8) {
                    Image(systemName: icon(for: action))
                        .foregroundStyle(color(for: action))
                        .frame(width: 18)
                        .accessibilityLabel(verb(for: action))
                    Text(action.relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(detail(for: action))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        } else {
            VStack(spacing: 6) {
                Image(systemName: placeholderIcon)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(placeholderText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var isDone: Bool {
        if case .done = model.phase { return true }
        return false
    }

    private var placeholderIcon: String {
        switch model.phase {
        case .failed: return "exclamationmark.triangle"
        case .done:   return "checkmark.circle"
        case .ready:  return "checkmark.circle"
        default:      return "arrow.triangle.2.circlepath"
        }
    }

    private var placeholderText: String {
        switch model.phase {
        case .idle:              return "Compare the folders to see what syncing would do."
        case .comparing:         return "Comparing the two folders\u{2026}"
        case .ready:             return "The folders are already in sync."
        case .applying:
            return model.isWaitingToDelete
                ? "Transferring\u{2026}\nItems are only deleted once every transfer has finished."
                : "Syncing\u{2026}"
        case .done(let message): return message
        case .failed(let error): return error
        }
    }

    private var statusLine: String {
        guard model.phase == .ready, let plan = model.plan, plan.hasChanges else { return "" }
        var parts = ["\(plan.transfers.count) to \(model.direction == .upload ? "upload" : "download")"]
        if plan.totalBytes > 0 {
            parts[0] += " (\(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)))"
        }
        if !plan.deletions.isEmpty { parts.append("\(plan.deletions.count) to delete") }
        if !plan.skips.isEmpty { parts.append("\(plan.skips.count) skipped") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var deletionQuestion: String {
        let count = model.plan?.deletions.count ?? 0
        let items = count == 1 ? "1 item" : "\(count) items"
        return model.direction == .upload
            ? "Sync and delete \(items) from the server?"
            : "Sync and move \(items) to the Trash?"
    }

    /// Deletions get one more "are you sure", stating how many.
    private func startSync() {
        if model.plan?.deletions.isEmpty == false {
            confirmingDeletions = true
        } else {
            Task { await model.apply() }
        }
    }

    private func verb(for action: SyncAction) -> String {
        switch action.kind {
        case .transfer:        return model.direction == .upload ? "Upload" : "Download"
        case .createDirectory: return "Create folder"
        case .delete:          return "Delete"
        case .skip:            return "Skip"
        }
    }

    private func icon(for action: SyncAction) -> String {
        switch action.kind {
        case .transfer:        return model.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        case .createDirectory: return "folder.badge.plus"
        case .delete:          return "trash"
        case .skip:            return "minus.circle"
        }
    }

    private func color(for action: SyncAction) -> Color {
        switch action.kind {
        case .transfer:        return model.direction == .upload ? .green : .blue
        case .createDirectory: return .secondary
        case .delete:          return .red
        case .skip:            return .orange
        }
    }

    private func detail(for action: SyncAction) -> String {
        switch action.kind {
        case .transfer:
            let size = action.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return [action.reason, size].compactMap { $0 }.joined(separator: " \u{00B7} ")
        case .createDirectory, .delete, .skip:
            return action.reason
        }
    }
}
