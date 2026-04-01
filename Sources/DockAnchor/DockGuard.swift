import AppKit
import CoreGraphics
import os

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
/// CFRunLoop). All mutable state accessed from the callback is protected by
/// an `OSAllocatedUnfairLock`. The lock is held for nanoseconds (just reading
/// a few scalars), so there is no perceptible input latency.
///
/// # Security note
///
/// The event tap is installed at `.cghidEventTap` (HID level), which is the
/// most privileged tap point. This is required to modify events before
/// WindowServer processes them. The event mask is restricted to `.mouseMoved`
/// only — no other event types are intercepted or modified.
///
final class DockGuard: @unchecked Sendable {

    // MARK: - Public State

    /// Whether the event tap is currently installed and running.
    var isRunning: Bool {
        lock.withLock { _eventTap != nil }
    }

    /// Callback fired on the main thread when the event tap is disabled by
    /// the system (usually because Accessibility permission was revoked).
    var onEventTapDisabled: (() -> Void)?

    // MARK: - Private State

    /// Lock protecting ALL mutable state accessed from both the main thread
    /// and the event tap callback thread. This includes the event tap handle,
    /// run loop references, and the guarded configuration fields.
    private let lock = OSAllocatedUnfairLock()

    /// Event tap handle. Protected by `lock`.
    private var _eventTap: CFMachPort?

    /// Run loop source for the event tap. Protected by `lock`.
    private var _runLoopSource: CFRunLoopSource?

    /// The background thread's run loop. Protected by `lock`.
    private var _guardRunLoop: CFRunLoop?

    /// Signaled when the background thread has fully exited.
    private let threadExitSemaphore = DispatchSemaphore(value: 0)

    /// The display ID the user wants the Dock locked to. Protected by `lock`.
    private var _guardedPreferredDisplayID: CGDirectDisplayID = 0

    /// Whether guarding is enabled (user can toggle via menu). Protected by `lock`.
    private var _guardedEnabled: Bool = true

    /// Cached bounds of all connected displays. Protected by `lock`.
    private var _guardedDisplayBounds: [(id: CGDirectDisplayID, bounds: CGRect)] = []

    /// Retained self-reference that keeps this instance alive while the event
    /// tap callback holds a raw pointer to us. Set in `start()`, cleared in `stop()`.
    private var _retainedSelf: Unmanaged<DockGuard>?

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
        lock.lock()
        guard _eventTap == nil else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Seed the guarded state before installing the tap.
        updatePreferredDisplay(preferredDisplayID)
        updateDisplayBounds(displays)

        // Retain self so the raw pointer in the callback stays valid.
        // Released in stop() after the background thread has exited.
        _retainedSelf = Unmanaged.passRetained(self)

        // We want to intercept mouseMoved events globally.
        let eventMask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: dockGuardEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Accessibility permission not granted. Release the retain.
            _retainedSelf?.release()
            _retainedSelf = nil
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        lock.withLock {
            _eventTap = tap
            _runLoopSource = source
        }

        // Run the event tap on a dedicated thread so we never block the main
        // thread's run loop with event processing.
        let semaphore = threadExitSemaphore
        let thread = Thread { [weak self] in
            guard let self, let source else {
                semaphore.signal()
                return
            }
            let rl = CFRunLoopGetCurrent()!
            self.lock.withLock { self._guardRunLoop = rl }
            CFRunLoopAddSource(rl, source, .commonModes)
            CFRunLoopRun()
            // Run loop has exited — signal that we're done.
            semaphore.signal()
        }
        thread.name = "com.dockanchor.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the event tap and synchronously waits for the background thread
    /// to exit before returning. Safe to call from the main thread.
    func stop() {
        let (tap, source, rl) = lock.withLock { () -> (CFMachPort?, CFRunLoopSource?, CFRunLoop?) in
            let t = _eventTap
            let s = _runLoopSource
            let r = _guardRunLoop
            _eventTap = nil
            _runLoopSource = nil
            _guardRunLoop = nil
            return (t, s, r)
        }

        guard tap != nil else { return }

        // Disable the tap so no more callbacks fire.
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }

        // Stop the run loop so the background thread can exit.
        if let rl { CFRunLoopStop(rl) }

        // Wait for the background thread to fully exit before we release
        // the retained self-reference. This prevents use-after-free.
        threadExitSemaphore.wait()

        if let source, let rl {
            CFRunLoopRemoveSource(rl, source, .commonModes)
        }

        // Release the retain cycle now that the callback can no longer fire.
        _retainedSelf?.release()
        _retainedSelf = nil
    }

    // MARK: - State Updates (called from main thread)

    func updatePreferredDisplay(_ displayID: CGDirectDisplayID) {
        lock.withLock { _guardedPreferredDisplayID = displayID }
    }

    func updateDisplayBounds(_ displays: [DisplayInfo]) {
        let bounds = displays.map { (id: $0.id, bounds: CGDisplayBounds($0.id)) }
        lock.withLock { _guardedDisplayBounds = bounds }
    }

    func setEnabled(_ enabled: Bool) {
        let tap: CFMachPort? = lock.withLock {
            _guardedEnabled = enabled
            return _eventTap
        }

        // Enable/disable the tap itself to avoid unnecessary callback overhead.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: enabled)
        }
    }

    // MARK: - Event Callback Logic

    /// Called from the event tap callback (background thread).
    /// Returns the (possibly modified) event.
    fileprivate func handleMouseMoved(_ event: CGEvent) -> CGEvent {
        let (enabled, preferredID, displays) = lock.withLock {
            (_guardedEnabled, _guardedPreferredDisplayID, _guardedDisplayBounds)
        }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            let tap = self.lock.withLock { self._eventTap }
            guard let tap else { return }
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
        guard_.handleTapDisabled()
        return Unmanaged.passUnretained(event)

    default:
        return Unmanaged.passUnretained(event)
    }
}
