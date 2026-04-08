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
/// DockGuard installs a CGEventTap that intercepts `.mouseMoved` events and
/// tracks how long the cursor sits at the bottom edge of non-preferred displays.
///
/// - For the first 300ms, events pass through unmodified. This allows the
///   cursor to traverse screen edges normally (reaching other monitors,
///   Universal Control handoff, etc.).
/// - After 300ms of sustained dwell at the edge, DockGuard nudges the cursor
///   up by a few pixels. The WindowServer never sees a long enough dwell to
///   trigger Dock migration.
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
/// `start()` and `stop()` must be called from the main thread. The
/// `onEventTapDisabled` callback is always fired on the main thread.
///
/// # Security note
///
/// The event tap is installed at `.cghidEventTap` (HID level), which is the
/// most privileged tap point. This is required to modify events before
/// WindowServer processes them. The event mask is restricted to `.mouseMoved`
/// only — no other event types are intercepted or modified.
///
/// # Compatibility
///
/// The dwell-based approach is compatible with multi-monitor setups where
/// the cursor must pass through a screen's bottom edge to reach another
/// display, and with Universal Control / Barrier / Synergy where the
/// cursor crosses a screen edge to reach another machine.
///
final class DockGuard: @unchecked Sendable {

    // MARK: - Public State

    /// Whether the event tap is currently installed and running.
    var isRunning: Bool {
        lock.withLock { _eventTap != nil }
    }

    /// Callback fired on the main thread when the event tap is disabled by
    /// the system (usually because Accessibility permission was revoked).
    /// Must only be set from the main thread before calling `start()`.
    var onEventTapDisabled: (() -> Void)?

    // MARK: - Private State

    /// Lock protecting ALL mutable state accessed from both the main thread
    /// and the event tap callback thread.
    private let lock = OSAllocatedUnfairLock()

    /// Event tap handle. Protected by `lock`.
    private var _eventTap: CFMachPort?

    /// Run loop source for the event tap. Protected by `lock`.
    private var _runLoopSource: CFRunLoopSource?

    /// The background thread's run loop. Protected by `lock`.
    private var _guardRunLoop: CFRunLoop?

    /// Semaphore signaled when the background thread exits. A new semaphore
    /// is created for each start/stop cycle to prevent cross-cycle confusion.
    /// Protected by `lock`.
    private var _threadExitSemaphore: DispatchSemaphore?

    /// The display ID the user wants the Dock locked to. Protected by `lock`.
    private var _guardedPreferredDisplayID: CGDirectDisplayID = 0

    /// Whether guarding is enabled (user can toggle via menu). Protected by `lock`.
    private var _guardedEnabled: Bool = true

    /// Cached bounds of all connected displays. Protected by `lock`.
    private var _guardedDisplayBounds: [(id: CGDirectDisplayID, bounds: CGRect)] = []

    /// Retained self-reference that keeps this instance alive while the event
    /// tap callback holds a raw pointer to us. Protected by `lock`.
    private var _retainedSelf: Unmanaged<DockGuard>?

    // -- Dwell tracking (protected by `lock`) --

    /// Timestamp (CFAbsoluteTime) when the cursor first entered the bottom
    /// edge zone on a non-preferred display. 0 means not dwelling.
    private var _dwellStartTime: CFAbsoluteTime = 0

    /// Which display the cursor was dwelling on (to detect display changes).
    private var _dwellDisplayID: CGDirectDisplayID = 0

    /// How close (in points) to the bottom edge counts as the "danger zone"
    /// where Dock migration can trigger. macOS triggers at ~1-2px.
    private let edgeThreshold: CGFloat = 4

    /// How long (in seconds) the cursor can sit at the bottom edge before
    /// we start nudging. macOS triggers Dock migration at ~0.5-1.0 seconds,
    /// but may count total bottom-edge time across display transitions.
    /// 100ms is enough for cursor traversal between screens (~50ms typical)
    /// while blocking Dock migration well before macOS triggers it.
    private let dwellTimeout: CFAbsoluteTime = 0.1

    // MARK: - Accessibility Check

    /// Returns `true` if the app has Accessibility permission.
    /// If `prompt` is true, shows the system prompt asking the user to grant it.
    static func checkAccessibility(prompt: Bool = false) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Start / Stop

    func start(preferredDisplayID: CGDirectDisplayID, displays: [DisplayInfo]) {
        // The entire start sequence is atomic with respect to the lock to
        // prevent races if start() is called from multiple threads.
        lock.lock()
        guard _eventTap == nil else {
            lock.unlock()
            return
        }

        // Seed the guarded state while we still hold the lock.
        _guardedPreferredDisplayID = preferredDisplayID
        _guardedDisplayBounds = displays.map { (id: $0.id, bounds: CGDisplayBounds($0.id)) }

        // Retain self so the raw pointer in the callback stays valid.
        // Released in stop() after the background thread has exited.
        _retainedSelf = Unmanaged.passRetained(self)

        // Create a fresh semaphore for this start/stop cycle.
        let semaphore = DispatchSemaphore(value: 0)
        _threadExitSemaphore = semaphore

        lock.unlock()

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
            // Accessibility permission not granted. Clean up the retain.
            lock.withLock {
                _retainedSelf?.release()
                _retainedSelf = nil
                _threadExitSemaphore = nil
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        lock.withLock {
            _eventTap = tap
            _runLoopSource = source
        }

        // Run the event tap on a dedicated thread so we never block the main
        // thread's run loop with event processing.
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
        let (tap, rl, semaphore) = lock.withLock {
            () -> (CFMachPort?, CFRunLoop?, DispatchSemaphore?) in
            let t = _eventTap
            let r = _guardRunLoop
            let s = _threadExitSemaphore
            _eventTap = nil
            _runLoopSource = nil
            _guardRunLoop = nil
            _threadExitSemaphore = nil
            return (t, r, s)
        }

        guard tap != nil else { return }

        // Disable the tap so no more callbacks fire.
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }

        // Stop the run loop so the background thread can exit.
        if let rl { CFRunLoopStop(rl) }

        // Wait for the background thread to fully exit before we release
        // the retained self-reference. This prevents use-after-free.
        semaphore?.wait()

        // Release the retain now that the callback can no longer fire.
        lock.withLock {
            _retainedSelf?.release()
            _retainedSelf = nil
        }
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

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: enabled)
        }
    }

    // MARK: - Event Callback Logic

    /// Called from the event tap callback (background thread).
    /// Returns the (possibly modified) event.
    ///
    /// # Dwell-based detection
    ///
    /// Instead of unconditionally blocking the bottom edge (which would break
    /// multi-monitor cursor traversal and Universal Control), we track how
    /// long the cursor has been sitting at the edge. The cursor passes through
    /// freely for the first `dwellTimeout` (300ms). Only after that do we
    /// start nudging it up to prevent Dock migration. This means:
    ///
    /// - Moving the cursor through the bottom edge to another monitor: works
    /// - Universal Control handoff through the bottom edge: works
    /// - Dwelling at the bottom edge (Dock migration trigger): blocked
    ///
    fileprivate func handleMouseMoved(_ event: CGEvent) -> CGEvent {
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let enabled = _guardedEnabled
        let preferredID = _guardedPreferredDisplayID
        let displays = _guardedDisplayBounds
        let dwellStart = _dwellStartTime
        let dwellDisplay = _dwellDisplayID
        lock.unlock()

        guard enabled, preferredID != 0, displays.count > 1 else {
            return event
        }

        let location = event.location  // CG coordinates: top-left origin

        // Determine which display the cursor is on.
        // Note: CGRect.contains() uses half-open intervals [min, max), so a
        // point at exactly maxX or maxY returns false. We must expand the
        // check by 1px to catch the cursor sitting at the very bottom/right
        // edge of a display — exactly where Dock migration triggers.
        var currentDisplayID: CGDirectDisplayID = 0
        var currentBounds: CGRect = .zero

        for display in displays {
            let b = display.bounds
            let inBounds = location.x >= b.minX && location.x <= b.maxX
                        && location.y >= b.minY && location.y <= b.maxY
            if inBounds {
                currentDisplayID = display.id
                currentBounds = b
                break
            }
        }

        // If cursor is on the preferred display or unrecognized, allow and reset dwell.
        if currentDisplayID == preferredID || currentDisplayID == 0 {
            if dwellStart != 0 {
                lock.withLock {
                    _dwellStartTime = 0
                    _dwellDisplayID = 0
                }
            }
            return event
        }

        // Cursor is on a non-preferred display.
        let distanceFromBottom = currentBounds.maxY - location.y
        let atBottomEdge = distanceFromBottom <= edgeThreshold

        if !atBottomEdge {
            // Cursor moved away from the edge — reset dwell tracking.
            if dwellStart != 0 {
                lock.withLock {
                    _dwellStartTime = 0
                    _dwellDisplayID = 0
                }
            }
            return event
        }

        // Cursor IS at the bottom edge of a non-preferred display.

        if dwellStart == 0 || dwellDisplay != currentDisplayID {
            // Just entered the edge zone (or switched displays). Start tracking.
            let displayForDwell = currentDisplayID
            lock.withLock {
                _dwellStartTime = now
                _dwellDisplayID = displayForDwell
            }
            // Allow the event through — the cursor may be passing through.
            return event
        }

        // Cursor has been at the edge for some time. Check duration.
        let dwellDuration = now - dwellStart

        if dwellDuration < dwellTimeout {
            // Still within the grace period — allow the event through.
            return event
        }

        // Dwell timeout exceeded — physically move the cursor away from the
        // edge using CGWarpMouseCursorPosition. Simply modifying event.location
        // is not enough: when the cursor is stationary, no mouseMoved events
        // fire, and macOS's dock migration timer continues to see the cursor
        // at the edge. CGWarp actually repositions the cursor at the OS level.
        let nudgedY = currentBounds.maxY - edgeThreshold - 1
        let nudgedPoint = CGPoint(x: location.x, y: nudgedY)
        CGWarpMouseCursorPosition(nudgedPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
        event.location = nudgedPoint
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
