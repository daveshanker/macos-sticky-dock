import Foundation
import ServiceManagement

/// Manages registering and unregistering the app as a login item using SMAppService.
@MainActor
final class LaunchAtLoginManager {

    // MARK: - Properties

    /// Whether the app is currently registered as a login item.
    var isEnabled: Bool {
        get {
            SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("LaunchAtLogin: Failed to \(newValue ? "enable" : "disable"): \(error)")
            }
        }
    }
}
