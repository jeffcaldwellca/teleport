import Foundation
import Observation

/// User preferences persisted via UserDefaults.
@Observable
@MainActor
final class Preferences {

    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    // MARK: - Stored prefs

    private struct Keys {
        static let maxConcurrentTransfers = "pref.maxConcurrentTransfers"
        static let defaultConflict        = "pref.defaultConflict"
        static let showHiddenByDefault    = "pref.showHiddenByDefault"
        static let downloadDestination    = "pref.downloadDestination"   // raw value of DownloadDestinationChoice
        static let fileListTextSize       = "pref.fileListTextSize"      // raw value of FileListTextSize
    }

    // Downloads started from the remote pane land in the folder the local
    // pane is showing, like every two-pane client. Older builds stored
    // "downloads" (and before that "desktop") here; both read as .localPane.
    enum DownloadDestinationChoice: String, CaseIterable, Identifiable {
        case localPane, ask
        var id: String { rawValue }
        var label: String {
            switch self {
            case .localPane: return "Local pane\u{2019}s folder"
            case .ask:       return "Ask each time"
            }
        }
    }

    enum DefaultConflict: String, CaseIterable, Identifiable {
        case ask, overwrite, overwriteIfNewer, autoRename, skip
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ask:               return "Ask"
            case .overwrite:         return "Overwrite"
            case .overwriteIfNewer:  return "Overwrite if newer"
            case .autoRename:        return "Auto-rename"
            case .skip:              return "Skip"
            }
        }
    }

    /// Text size for the browser panes' file lists, Finder-style. `.medium` is
    /// the system body size, so the default renders exactly as before the
    /// setting existed. Icon size and row padding scale with the text so the
    /// list stays balanced at every step.
    enum FileListTextSize: String, CaseIterable, Identifiable {
        case small, medium, large, extraLarge
        var id: String { rawValue }

        var label: String {
            switch self {
            case .small:      return "Small"
            case .medium:     return "Medium"
            case .large:      return "Large"
            case .extraLarge: return "Extra Large"
            }
        }

        var pointSize: CGFloat {
            switch self {
            case .small:      return 11
            case .medium:     return 13
            case .large:      return 15
            case .extraLarge: return 17
            }
        }

        /// Width of the icon slot in the Name column (20 pt at the default size).
        var iconSize: CGFloat {
            switch self {
            case .small:      return 17
            case .medium:     return 20
            case .large:      return 23
            case .extraLarge: return 26
            }
        }

        /// Extra vertical padding per cell; zero at and below the default so
        /// row heights are unchanged unless the text is enlarged.
        var rowPadding: CGFloat {
            switch self {
            case .small, .medium: return 0
            case .large:          return 2
            case .extraLarge:     return 4
            }
        }
    }

    // `@Observable` only instruments stored properties, so each of these
    // defaults-backed computed properties registers with the observation
    // registrar by hand. Without it, views that display the value (the
    // Settings stepper label, an open pane) don't re-render when it changes.

    var maxConcurrentTransfers: Int {
        get {
            access(keyPath: \.maxConcurrentTransfers)
            return max(1, defaults.object(forKey: Keys.maxConcurrentTransfers) as? Int ?? 3)
        }
        set {
            withMutation(keyPath: \.maxConcurrentTransfers) {
                defaults.set(max(1, newValue), forKey: Keys.maxConcurrentTransfers)
            }
        }
    }

    var defaultConflict: DefaultConflict {
        get {
            access(keyPath: \.defaultConflict)
            return DefaultConflict(rawValue: defaults.string(forKey: Keys.defaultConflict) ?? "") ?? .ask
        }
        set {
            withMutation(keyPath: \.defaultConflict) {
                defaults.set(newValue.rawValue, forKey: Keys.defaultConflict)
            }
        }
    }

    var showHiddenByDefault: Bool {
        get {
            access(keyPath: \.showHiddenByDefault)
            return defaults.bool(forKey: Keys.showHiddenByDefault)
        }
        set {
            withMutation(keyPath: \.showHiddenByDefault) {
                defaults.set(newValue, forKey: Keys.showHiddenByDefault)
            }
        }
    }

    var downloadDestination: DownloadDestinationChoice {
        get {
            access(keyPath: \.downloadDestination)
            return DownloadDestinationChoice(
                rawValue: defaults.string(forKey: Keys.downloadDestination) ?? ""
            ) ?? .localPane
        }
        set {
            withMutation(keyPath: \.downloadDestination) {
                defaults.set(newValue.rawValue, forKey: Keys.downloadDestination)
            }
        }
    }

    var fileListTextSize: FileListTextSize {
        get {
            access(keyPath: \.fileListTextSize)
            return FileListTextSize(rawValue: defaults.string(forKey: Keys.fileListTextSize) ?? "") ?? .medium
        }
        set {
            withMutation(keyPath: \.fileListTextSize) {
                defaults.set(newValue.rawValue, forKey: Keys.fileListTextSize)
            }
        }
    }

    private init() {}
}
