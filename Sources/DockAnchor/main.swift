import AppKit

// Integration Testing Checklist
// ==============================
// [ ] Dock never leaves preferred screen when cursor hits bottom of non-preferred screen
// [ ] Display unplug falls back gracefully
// [ ] Display replug re-acquires preferred screen
// [ ] Launch at login works after reboot
// [ ] CPU usage ~0% (event tap is interrupt-driven, no polling)
// [ ] Accessibility permission prompt appears on first launch
// [ ] Event tap recovers if permission is toggled off then on
// [ ] Menu bar icon visible and functional
// [ ] Display list updates when monitors connect/disconnect
// [ ] "Enabled" toggle pauses/resumes the event tap
// [ ] Quit terminates cleanly

/// Application delegate that owns all managers and wires them together.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Managers

    private let displayManager = DisplayManager()
    private let dockGuard = DockGuard()
    private let launchAtLogin = LaunchAtLoginManager()
    private let preferencesStore = PreferencesStore()
    private var menuBarController: MenuBarController!

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController(
            preferencesStore: preferencesStore,
            displayProvider: displayManager,
            launchAtLogin: launchAtLogin
        )

        wireCallbacks()
        startServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockGuard.stop()
        displayManager.stopObserving()
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        // --- Display configuration changes ---
        displayManager.onDisplaysChanged = { [weak self] displays in
            guard let self else { return }
            self.menuBarController.rebuildMenu()
            self.dockGuard.updateDisplayBounds(displays)
            self.handleDisplayTopologyChange(displays)
        }

        // --- User selected a different preferred display from the menu ---
        menuBarController.onPreferredDisplayChanged = { [weak self] newDisplayID in
            guard let self else { return }
            self.dockGuard.updatePreferredDisplay(newDisplayID)
        }

        // --- User toggled monitoring enabled/disabled ---
        menuBarController.onMonitoringEnabledChanged = { [weak self] enabled in
            guard let self else { return }
            self.dockGuard.setEnabled(enabled)
        }

        // --- Event tap was disabled (Accessibility permission revoked) ---
        dockGuard.onEventTapDisabled = { [weak self] in
            guard let self else { return }
            self.promptForAccessibility()
        }
    }

    private func startServices() {
        displayManager.startObserving()

        // Default preferred display to whichever currently hosts the Dock.
        if preferencesStore.preferredDisplayID == nil {
            preferencesStore.preferredDisplayID = displayManager.dockDisplayID
        }

        // Check Accessibility permission and start the event tap.
        if DockGuard.checkAccessibility(prompt: false) {
            startGuard()
        } else {
            // Prompt on first launch. The event tap will start once granted.
            promptForAccessibility()
        }
    }

    private func startGuard() {
        let preferredID = preferencesStore.preferredDisplayID ?? CGMainDisplayID()
        dockGuard.start(
            preferredDisplayID: preferredID,
            displays: displayManager.connectedDisplays
        )
        dockGuard.setEnabled(preferencesStore.monitoringEnabled)

        if !dockGuard.isRunning {
            // Tap creation failed — likely Accessibility not yet granted.
            // Poll briefly until the user grants it.
            pollForAccessibilityPermission()
        }
    }

    // MARK: - Accessibility Permission

    private func promptForAccessibility() {
        // Trigger the system prompt (opens System Settings automatically).
        _ = DockGuard.checkAccessibility(prompt: true)

        // Poll until the user grants permission.
        pollForAccessibilityPermission()
    }

    private var accessibilityPollTimer: Timer?

    /// Polls every 2 seconds for Accessibility permission. Once granted,
    /// starts the event tap and stops polling.
    private func pollForAccessibilityPermission() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if DockGuard.checkAccessibility(prompt: false) {
                    timer.invalidate()
                    self.accessibilityPollTimer = nil
                    if !self.dockGuard.isRunning {
                        self.startGuard()
                    }
                }
            }
        }
    }

    // MARK: - Display Topology Change Handling

    private func handleDisplayTopologyChange(_ currentDisplays: [DisplayInfo]) {
        guard let preferredID = preferencesStore.preferredDisplayID else { return }

        let preferredStillConnected = currentDisplays.contains { $0.id == preferredID }

        if !preferredStillConnected {
            // Preferred display disconnected. Fall back to built-in or primary.
            // Keep the original preference for re-acquisition on reconnect.
            let fallbackID = currentDisplays.first(where: { $0.isBuiltIn })?.id
                ?? currentDisplays.first?.id
                ?? CGMainDisplayID()
            dockGuard.updatePreferredDisplay(fallbackID)
        } else {
            // Preferred display is (still) connected — ensure guard targets it.
            dockGuard.updatePreferredDisplay(preferredID)
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate

app.run()
