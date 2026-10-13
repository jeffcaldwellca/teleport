import SwiftUI
import TeleportKit

@main
struct TeleportApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    init() {
        TemporaryFiles.sweepStale()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { appDelegate.transferQueue = appState.transferQueue }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            TeleportCommands()
        }

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

// MARK: - App Delegate

/// Quitting discards the transfer queue, so ask first while it has work in it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var transferQueue: TransferQueueViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let queue = transferQueue, queue.hasUnfinishedTransfers else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Transfers are still in progress"
        alert.informativeText = "Quitting now stops them. Unfinished downloads keep their partial files, but the queue isn't restored when Teleport reopens."
        alert.addButton(withTitle: "Quit Anyway")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

// MARK: - App Commands

struct TeleportCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                NotificationCenter.default.post(name: .newConnection, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        // Browser navigation. These post notifications consumed by the active
        // pane (whichever one has focus) — see `.onReceive` in BrowserPaneView.
        CommandMenu("Go") {
            Button("Refresh") {
                NotificationCenter.default.post(name: .browserRefresh, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Parent Folder") {
                NotificationCenter.default.post(name: .browserGoUp, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("Back") {
                NotificationCenter.default.post(name: .browserGoBack, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Button("Forward") {
                NotificationCenter.default.post(name: .browserGoForward, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)

            Button("Go to Folder…") {
                NotificationCenter.default.post(name: .browserGoToFolder, object: nil)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Divider()

            Button("Switch Pane") {
                NotificationCenter.default.post(name: .switchPane, object: nil)
            }
            .keyboardShortcut(.tab, modifiers: .control)
        }

        CommandMenu("Session") {
            Button("Next Session") {
                NotificationCenter.default.post(name: .sessionNext, object: nil)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])

            Button("Previous Session") {
                NotificationCenter.default.post(name: .sessionPrevious, object: nil)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            Button("Close Session") {
                NotificationCenter.default.post(name: .sessionClose, object: nil)
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandMenu("View") {
            Button("Toggle Hidden Files") {
                NotificationCenter.default.post(name: .browserToggleHidden, object: nil)
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Button("Toggle Transfer Queue") {
                NotificationCenter.default.post(name: .toggleTransferQueue, object: nil)
            }
            .keyboardShortcut("y", modifiers: [.command, .shift])
        }
    }
}

extension Notification.Name {
    static let newConnection       = Notification.Name("com.teleport.newConnection")
    static let browserRefresh      = Notification.Name("com.teleport.browser.refresh")
    static let browserGoUp         = Notification.Name("com.teleport.browser.up")
    static let browserGoBack       = Notification.Name("com.teleport.browser.back")
    static let browserGoForward    = Notification.Name("com.teleport.browser.forward")
    static let browserGoToFolder   = Notification.Name("com.teleport.browser.goToFolder")
    static let browserToggleHidden = Notification.Name("com.teleport.browser.toggleHidden")
    static let toggleTransferQueue = Notification.Name("com.teleport.queue.toggle")
    static let sessionNext         = Notification.Name("com.teleport.session.next")
    static let sessionPrevious     = Notification.Name("com.teleport.session.previous")
    static let sessionClose        = Notification.Name("com.teleport.session.close")
    static let switchPane          = Notification.Name("com.teleport.switchPane")
    static let transferCompleted   = Notification.Name("com.teleport.transferCompleted")
    static let localRootChanged    = Notification.Name("com.teleport.localRootChanged")
}
