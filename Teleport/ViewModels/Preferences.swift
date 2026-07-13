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

    private init() {}
}
