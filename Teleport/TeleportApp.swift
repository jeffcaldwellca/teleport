import SwiftUI

@main
struct TeleportApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 560)
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

            Divider()

            Button("Switch Pane") {
                NotificationCenter.default.post(name: .switchPane, object: nil)
            }
            .keyboardShortcut(.tab, modifiers: .control)
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
    static let browserToggleHidden = Notification.Name("com.teleport.browser.toggleHidden")
    static let toggleTransferQueue = Notification.Name("com.teleport.queue.toggle")
    static let switchPane          = Notification.Name("com.teleport.switchPane")
    static let transferCompleted   = Notification.Name("com.teleport.transferCompleted")
    static let localRootChanged    = Notification.Name("com.teleport.localRootChanged")
}
