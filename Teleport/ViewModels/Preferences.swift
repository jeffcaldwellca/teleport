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

    // "Desktop" was removed as a choice: under the App Sandbox it silently
    // resolved to the app container's Desktop folder, so downloads appeared to
    // vanish. A stored "desktop" value falls back to .downloads on read.
    enum DownloadDestinationChoice: String, CaseIterable, Identifiable {
        case downloads, ask
        var id: String { rawValue }
        var label: String {
            switch self {
            case .downloads: return "Downloads"
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

    var maxConcurrentTransfers: Int {
        get { max(1, defaults.object(forKey: Keys.maxConcurrentTransfers) as? Int ?? 3) }
        set { defaults.set(max(1, newValue), forKey: Keys.maxConcurrentTransfers) }
    }

    var defaultConflict: DefaultConflict {
        get {
            DefaultConflict(rawValue: defaults.string(forKey: Keys.defaultConflict) ?? "") ?? .ask
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.defaultConflict) }
    }

    var showHiddenByDefault: Bool {
        get { defaults.bool(forKey: Keys.showHiddenByDefault) }
        set { defaults.set(newValue, forKey: Keys.showHiddenByDefault) }
    }

    var downloadDestination: DownloadDestinationChoice {
        get {
            DownloadDestinationChoice(
                rawValue: defaults.string(forKey: Keys.downloadDestination) ?? ""
            ) ?? .downloads
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.downloadDestination) }
    }

    var fileListTextSize: FileListTextSize {
        get {
            FileListTextSize(rawValue: defaults.string(forKey: Keys.fileListTextSize) ?? "") ?? .medium
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.fileListTextSize) }
    }

    private init() {}
}
