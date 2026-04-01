import AppKit
import CoreGraphics

/// Prevents the Dock from migrating to non-preferred displays by intercepting
/// mouse events via a CGEventTap.
///
/// # How it works
///
/// macOS migrates the Dock to a new screen when the cursor dwells at the very
/// bottom edge (within ~2px) of that screen for approximately 0.5–1 second.
/// DockGuard installs a CGEventTap that intercepts `.mouseMoved` events and,
/// when it detects the cursor approaching the bottom edge of a non-preferred
/// display, nudges the cursor up by a few pixels. The WindowServer never sees
/// the sustained bottom-edge dwell, so the Dock never migrates.
///
/// # Permissions
///
/// CGEventTap in `.defaultTap` mode (able to modify events) requires the app
/// to be listed in System Settings → Privacy & Security → Accessibility.
/// Without this permission, `CGEvent.tapCreate` returns nil.
///
/// # Threading
///
/// The event tap callback runs on a dedicated background thread (its own
/// CFRunLoop). All mutable state accessed from the callback uses `os_unfair_lock`
/// for thread safety. The lock is held for nanoseconds (just reading a few
/// scalars), so there is no perceptible input latency.
///
final class DockGuard {

    // MARK: - Public State

    var isRunning: Bool { eventTap != nil }

    /// Callback fired on the main thread when the event tap is disabled by
    /// the system (usually because Accessibility permission was revoked).
    var onEventTapDisabled: (() -> Void)?

    // MARK: - Private State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var guardRunLoop: CFRunLoop?

    /// Lock protecting all `_guarded*` fields accessed from the event callback.
    private var lock = os_unfair_lock()

    /// The display ID the user wants the Dock locked to.
    private var _guardedPreferredDisplayID: CGDirectDisplayID = 0

    /// Whether guarding is enabled (user can toggle via menu).
    private var _guardedEnabled: Bool = true

    /// Cached bounds of all connected displays, keyed by display ID.
    /// Updated on the main thread when displays change; read from the callback.
    private var _guardedDisplayBounds: [(id: CGDirectDisplayID, bounds: CGRect)] = []

    /// How close (in points) to the bottom edge the cursor must be before we
    /// intervene. macOS triggers Dock migration at ~1-2px from the edge.
    /// We use a slightly larger zone to catch it reliably.
    private let edgeThreshold: CGFloat = 5

    // MARK: - Accessibility Check

    /// Returns `true` if the app has Accessibility permission.
    /// If `prompt` is true, shows the system prompt asking the user to grant it.
    static func checkAccessibility(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Start / Stop

    func start(preferredDisplayID: CGDirectDisplayID, displays: [DisplayInfo]) {
        guard eventTap == nil else { return }

        // Seed the guarded state before installing the tap.
        updatePreferredDisplay(preferredDisplayID)
        updateDisplayBounds(displays)

        // We want to intercept mouseMoved events globally.
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,           // Allows modifying/blocking events
            eventsOfInterest: eventMask,
            callback: dockGuardEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Most likely: Accessibility permission not granted.
            return
        }

        eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        // Run the event tap on a dedicated thread so we never block the main
        // thread's run loop with event processing.
        let thread = Thread { [weak self] in
            guard let source else { return }
            let rl = CFRunLoopGetCurrent()!
            self?.guardRunLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "com.dockanchor.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let rl = guardRunLoop {
            CFRunLoopStop(rl)
        }
        if let source = runLoopSource, let rl = guardRunLoop {
            CFRunLoopRemoveSource(rl, source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        guardRunLoop = nil
    }

    // MARK: - State Updates (called from main thread)

    func updatePreferredDisplay(_ displayID: CGDirectDisplayID) {
        os_unfair_lock_lock(&lock)
        _guardedPreferredDisplayID = displayID
        os_unfair_lock_unlock(&lock)
    }

    func updateDisplayBounds(_ displays: [DisplayInfo]) {
        let bounds = displays.map { (id: $0.id, bounds: CGDisplayBounds($0.id)) }
        os_unfair_lock_lock(&lock)
        _guardedDisplayBounds = bounds
        os_unfair_lock_unlock(&lock)
    }

    func setEnabled(_ enabled: Bool) {
        os_unfair_lock_lock(&lock)
        _guardedEnabled = enabled
        os_unfair_lock_unlock(&lock)

        // Also enable/disable the tap itself to avoid unnecessary overhead.
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: enabled)
        }
    }

    // MARK: - Event Callback Logic

    /// Called from the event tap callback (background thread).
    /// Returns the (possibly modified) event, or nil to suppress it.
    fileprivate func handleMouseMoved(_ event: CGEvent) -> CGEvent {
        os_unfair_lock_lock(&lock)
        let enabled = _guardedEnabled
        let preferredID = _guardedPreferredDisplayID
        let displays = _guardedDisplayBounds
        os_unfair_lock_unlock(&lock)

        guard enabled, preferredID != 0, displays.count > 1 else {
            return event
        }

        let location = event.location  // CG coordinates: top-left origin

        // Determine which display the cursor is on.
        var currentDisplayID: CGDirectDisplayID = 0
        var currentBounds: CGRect = .zero

        for display in displays {
            if display.bounds.contains(location) {
                currentDisplayID = display.id
                currentBounds = display.bounds
                break
            }
        }

        // If cursor is on the preferred display, allow everything.
        if currentDisplayID == preferredID || currentDisplayID == 0 {
            return event
        }

        // Cursor is on a non-preferred display.
        // Check if it's near the bottom edge (CG coords: bottom = maxY).
        let distanceFromBottom = currentBounds.maxY - location.y

        if distanceFromBottom <= edgeThreshold {
            // Nudge the cursor up so it never dwells at the very bottom edge.
            // This prevents macOS from triggering Dock migration.
            var nudgedLocation = location
            nudgedLocation.y = currentBounds.maxY - edgeThreshold - 1
            event.location = nudgedLocation
        }

        return event
    }

    /// Called when the system disables our event tap (e.g., Accessibility
    /// permission revoked). We re-enable it after a delay, and notify the UI.
    fileprivate func handleTapDisabled() {
        // Try to re-enable after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let tap = self.eventTap else { return }
            if DockGuard.checkAccessibility() {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                self.onEventTapDisabled?()
            }
        }
    }
}

// MARK: - C Callback

/// Free function required by `CGEvent.tapCreate`. Dispatches to the
/// DockGuard instance via the userInfo pointer.
private func dockGuardEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let guard_ = Unmanaged<DockGuard>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .mouseMoved:
        let result = guard_.handleMouseMoved(event)
        return Unmanaged.passUnretained(result)

    case .tapDisabledByUserInput, .tapDisabledByTimeout:
        // The system disabled our tap — try to recover.
        guard_.handleTapDisabled()
        return Unmanaged.passUnretained(event)

    default:
        return Unmanaged.passUnretained(event)
    }
}
