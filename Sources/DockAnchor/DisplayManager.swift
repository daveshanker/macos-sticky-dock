import AppKit
import CoreGraphics

/// Enumerates connected displays and observes display configuration changes.
@MainActor
final class DisplayManager: DisplayProviding {

    // MARK: - DisplayProviding

    private(set) var connectedDisplays: [DisplayInfo] = []

    /// Returns the CGDirectDisplayID of the screen that currently hosts the Dock.
    ///
    /// Detection works by comparing each screen's `frame` to its `visibleFrame`.
    /// The Dock occupies space along one edge, so the screen hosting it will have
    /// a visible-frame inset on the bottom, left, or right relative to its full frame.
    /// The menu bar insets the *top* of the primary screen, so we exclude that edge.
    var dockDisplayID: CGDirectDisplayID? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        for screen in screens {
            let full = screen.frame
            let visible = screen.visibleFrame

            let isPrimaryScreen = (screen == screens.first)

            // Bottom dock: visibleFrame.origin.y is higher than frame.origin.y
            let bottomInset = visible.minY - full.minY
            if bottomInset > 10 {
                return displayID(for: screen)
            }

            // Left dock: visibleFrame.origin.x is shifted right from frame.origin.x
            let leftInset = visible.minX - full.minX
            if leftInset > 10 {
                return displayID(for: screen)
            }

            // Right dock: visibleFrame right edge is less than frame right edge
            // Exclude the small rounding differences by using a threshold.
            let rightInset = full.maxX - visible.maxX
            if rightInset > 10 {
                return displayID(for: screen)
            }

            // Top inset exists on the primary screen due to the menu bar.
            // On non-primary screens, a top inset could theoretically indicate
            // a top-positioned dock, but macOS does not support top dock placement.
            // For non-primary screens with no other inset, the dock is not here.
            if !isPrimaryScreen {
                let topInset = full.maxY - visible.maxY
                if topInset > 10 {
                    // Unexpected, but treat as dock present for robustness.
                    return displayID(for: screen)
                }
            }
        }

        // Fallback: if no screen shows a dock inset (e.g., Dock is auto-hidden),
        // return the primary screen's display ID as a best guess.
        if let primary = screens.first {
            return displayID(for: primary)
        }
        return nil
    }

    var onDisplaysChanged: (([DisplayInfo]) -> Void)?

    // MARK: - Private State

    private var screenObserver: NSObjectProtocol?

    // MARK: - Observation

    func startObserving() {
        refreshDisplays()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenParametersChanged()
            }
        }
    }

    func stopObserving() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
    }

    func displayInfo(for id: CGDirectDisplayID) -> DisplayInfo? {
        return connectedDisplays.first { $0.id == id }
    }

    // MARK: - Private Helpers

    private func handleScreenParametersChanged() {
        refreshDisplays()
    }

    private func refreshDisplays() {
        let screens = NSScreen.screens

        // Guard against transient empty screen lists during sleep/wake.
        guard !screens.isEmpty else { return }

        let newDisplays = screens.compactMap { screen -> DisplayInfo? in
            guard let id = displayID(for: screen) else { return nil }
            let name = screen.localizedName
            let isBuiltIn = CGDisplayIsBuiltin(id) != 0
            return DisplayInfo(
                id: id,
                name: name,
                isBuiltIn: isBuiltIn,
                frame: screen.frame
            )
        }

        let changed = (newDisplays.map(\.id) != connectedDisplays.map(\.id))
        connectedDisplays = newDisplays

        if changed {
            onDisplaysChanged?(newDisplays)
        }
    }

    /// Extracts the CGDirectDisplayID from an NSScreen's device description.
    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}
