import AppKit
import Foundation
import UserNotifications

// MARK: - File list dates

/// Finder-style dates for the file lists: "Today at 9:41 AM" for recent files,
/// the actual date for older ones — never just "2 years ago".
enum FileListDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func string(for date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - Temporary files

/// Remote files fetched for editing, previewing, duplicating or dragging out
/// are staged in per-use folders under the temporary directory. Nothing
/// removes them while the app runs (an editor may still have the file open),
/// so leftovers from earlier runs are swept at launch.
enum TemporaryFiles {
    private static let prefixes = ["Edit-", "Duplicate-", "Drag-"]
    private static let exactNames = ["QuickLook"]

    static func sweepStale(in base: URL = FileManager.default.temporaryDirectory) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: base.path) else { return }
        for name in names where exactNames.contains(name) || prefixes.contains(where: name.hasPrefix) {
            try? fm.removeItem(at: base.appending(component: name))
        }
    }
}

// MARK: - Transfer activity

/// Tells the user a run of transfers has finished when they aren't looking at
/// the app: a Dock bounce, plus a notification if they allow them.
@MainActor
enum TransferActivityNotifier {

    static func queueDidFinish(_ summary: TransferQueueViewModel.IdleSummary) {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = summary.failed == 0 ? "Transfers complete" : "Transfers finished with errors"
            content.body = body(for: summary)
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    static func body(for summary: TransferQueueViewModel.IdleSummary) -> String {
        func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
        switch (summary.completed, summary.failed) {
        case (let done, 0):      return "\(files(done)) transferred."
        case (0, let failed):    return "\(files(failed)) failed."
        case (let done, let failed): return "\(files(done)) transferred, \(files(failed)) failed."
        }
    }

    static func updateDockBadge(remaining: Int) {
        NSApp.dockTile.badgeLabel = remaining > 0 ? "\(remaining)" : nil
    }
}
