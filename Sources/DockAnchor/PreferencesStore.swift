import CoreGraphics
import Foundation

/// Persists user preferences using UserDefaults.
@MainActor
final class PreferencesStore: PreferencesPersisting {

    // MARK: - Keys

    private enum Keys {
        static let preferredDisplayID = "preferredDisplayID"
        static let launchAtLogin = "launchAtLogin"
        static let monitoringEnabled = "monitoringEnabled"
    }

    // MARK: - Properties

    private let defaults: UserDefaults

    // MARK: - Initialization

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - PreferencesPersisting

    var preferredDisplayID: CGDirectDisplayID? {
        get {
            // UserDefaults returns 0 for unset integer keys; treat 0 as nil.
            let value = defaults.integer(forKey: Keys.preferredDisplayID)
            return value == 0 ? nil : CGDirectDisplayID(value)
        }
        set {
            if let id = newValue {
                defaults.set(Int(id), forKey: Keys.preferredDisplayID)
            } else {
                defaults.removeObject(forKey: Keys.preferredDisplayID)
            }
        }
    }

    var launchAtLogin: Bool {
        get {
            defaults.bool(forKey: Keys.launchAtLogin)
        }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
        }
    }

    // MARK: - Additional Settings

    /// Whether dock monitoring is enabled. Defaults to true.
    var monitoringEnabled: Bool {
        get {
            // If the key has never been set, default to true.
            if defaults.object(forKey: Keys.monitoringEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Keys.monitoringEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.monitoringEnabled)
        }
    }
}
