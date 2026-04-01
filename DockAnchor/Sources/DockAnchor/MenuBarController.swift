import AppKit

/// Manages the NSStatusItem in the macOS menu bar and builds the dropdown menu.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private let preferencesStore: PreferencesStore
    private let displayProvider: DisplayProviding
    private let launchAtLogin: LaunchAtLoginManager

    /// Called when the user selects a different preferred display from the menu.
    var onPreferredDisplayChanged: ((CGDirectDisplayID) -> Void)?

    /// Called when the user toggles the monitoring enabled state.
    var onMonitoringEnabledChanged: ((Bool) -> Void)?

    // MARK: - Initialization

    init(preferencesStore: PreferencesStore,
         displayProvider: DisplayProviding,
         launchAtLogin: LaunchAtLoginManager) {
        self.preferencesStore = preferencesStore
        self.displayProvider = displayProvider
        self.launchAtLogin = launchAtLogin
        super.init()
        setupStatusItem()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            // Use "dock.rectangle" on macOS 14+, fall back to "lock.fill".
            if let image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "DockAnchor") {
                button.image = image
            } else {
                let fallback = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "DockAnchor")
                button.image = fallback
            }
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
        rebuildMenu()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - Menu Construction

    /// Rebuilds the dropdown menu with the current list of displays and settings.
    func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        // --- Display selection section ---
        let header = NSMenuItem(title: "Lock Dock to:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let displays = displayProvider.connectedDisplays
        let preferredID = preferencesStore.preferredDisplayID

        for display in displays {
            let item = NSMenuItem(
                title: display.name,
                action: #selector(selectDisplay(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = display.id as NSNumber
            item.state = (display.id == preferredID) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // --- Enabled toggle ---
        let enabledItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = preferencesStore.monitoringEnabled ? .on : .off
        menu.addItem(enabledItem)

        menu.addItem(NSMenuItem.separator())

        // --- Launch at Login ---
        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(loginItem)

        // --- About ---
        let aboutItem = NSMenuItem(
            title: "About DockAnchor",
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        // --- Quit ---
        let quitItem = NSMenuItem(
            title: "Quit DockAnchor",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let displayID = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        let id = CGDirectDisplayID(displayID)
        preferencesStore.preferredDisplayID = id
        rebuildMenu()
        onPreferredDisplayChanged?(id)
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        preferencesStore.monitoringEnabled.toggle()
        rebuildMenu()
        onMonitoringEnabledChanged?(preferencesStore.monitoringEnabled)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newValue = !launchAtLogin.isEnabled
        launchAtLogin.isEnabled = newValue
        preferencesStore.launchAtLogin = newValue
        rebuildMenu()
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        // Bring the app to front so the about panel is visible.
        NSApplication.shared.activate(ignoringOtherApps: true)

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "DockAnchor",
            .applicationVersion: "1.0.0",
            .version: "1",
            .credits: NSAttributedString(
                string: "Keeps your Dock locked to one screen.\n\nOpen source under MIT License.\nhttps://github.com/dockanchor/dockanchor",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                ]
            ),
        ]
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
}
