# DockAnchor

**Keep your Dock on one screen.** DockAnchor is a lightweight macOS menu bar app that prevents the Dock from jumping between displays in multi-monitor setups.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

## The Problem

On macOS, the Dock automatically migrates to whichever screen you push your cursor against the bottom edge. If you have a preferred monitor for your Dock, this behavior is annoying -- you have to manually reclaim it every time.

## The Solution

DockAnchor sits in your menu bar and automatically moves the Dock back to your chosen display whenever macOS relocates it. No hacks, no private APIs, no System Integrity Protection workarounds.

## Features

- Lock the Dock to any connected display
- Automatically reclaims the Dock when it migrates
- Handles monitor connect/disconnect gracefully
- Near-zero CPU usage (pauses with single display)
- Launch at Login support
- Simple menu bar interface
- No private APIs -- App Store safe
- Open source (MIT License)

## Installation

### Build from Source

Requirements: Xcode 15+ / macOS 14 (Sonoma) or later

```bash
git clone https://github.com/YOUR_USERNAME/DockAnchor.git
cd DockAnchor
swift build -c release
# The binary is at .build/release/DockAnchor
```

Or open the project in Xcode:

```bash
open Package.swift
```

Then Build & Run (Cmd+R).

## Usage

1. Launch DockAnchor -- it appears as a dock icon in the menu bar
2. Click the icon, then under "Lock Dock to:" select your preferred display
3. That's it! The Dock will automatically return to your chosen display

### Menu Options

- **Lock Dock to: [display list]** -- Select which display should own the Dock. A checkmark indicates the current selection.
- **Enabled** -- Toggle monitoring on/off. When disabled, DockAnchor will not intervene when the Dock moves.
- **Launch at Login** -- Start DockAnchor automatically when you log in.
- **About DockAnchor** -- Version and project information.
- **Quit DockAnchor** -- Exit the app and stop all monitoring.

## How It Works

DockAnchor uses only public macOS APIs:

1. **Detection**: Polls `NSScreen.visibleFrame` every 0.5 seconds to detect when the Dock moves. The Dock consumes approximately 70px from one screen edge, creating a measurable difference between `frame` and `visibleFrame`.

2. **Relocation**: Uses `CGWarpMouseCursorPosition` to briefly move the cursor to the bottom edge of your preferred display, triggering macOS's native Dock reclaim behavior, then restores the cursor to its original position.

3. **Efficiency**: Monitoring automatically pauses when only one display is connected (CPU usage drops to approximately 0%).

4. **Fallback**: If the cursor warp method fails, DockAnchor falls back to writing the display preference via `defaults write com.apple.dock` and restarting the Dock process (causes a brief visual flicker).

### Why polling?

macOS does not provide a public notification for Dock screen changes. We evaluated four approaches:

| Approach | Verdict |
|---|---|
| `DistributedNotificationCenter` | No notification for Dock screen migration |
| `NSScreen.visibleFrame` polling | Reliable, no permissions, public API |
| `CGEventTap` | Requires Accessibility permissions, complex |
| `com.apple.dock` defaults observation | Undocumented key, unreliable |

Polling `visibleFrame` at 0.5s is the most reliable approach using only public APIs, with negligible CPU impact (< 0.1% on modern hardware).

## Architecture

```
DockAnchorApp          -- Main orchestrator, wires all modules together
  |
  +-- DisplayManager   -- Enumerates screens, detects which hosts the Dock
  +-- DockMonitor      -- Polls for Dock movement between screens
  +-- DockRelocator    -- Moves the Dock back via cursor warp or defaults
  +-- MenuBarController-- NSStatusItem menu bar UI
  +-- PreferencesStore -- UserDefaults persistence
  +-- LaunchAtLogin    -- SMAppService login item management
```

### Data Flow

```
DisplayManager --onDisplaysChanged--> App --> rebuild menu, check preferred display
DockMonitor    --onDockMoved--------> App --> relocate Dock if monitoring enabled
MenuBar        --onPreferredChanged-> App --> update preferences, relocate if needed
MenuBar        --onEnabledChanged---> App --> start/stop dock monitoring
```

## Permissions

**No special permissions required** for the default cursor warp method. DockAnchor does not need Accessibility permissions, Screen Recording, or any other protected entitlements.

If the primary method fails, the fallback (restarting the Dock process) may cause a brief visual flicker but still requires no special permissions.

## Comparison to Alternatives

| Feature | DockAnchor | Commercial alternatives |
|---------|-----------|----------------------|
| Price | Free | $5-10 |
| Open Source | MIT | No |
| Private APIs | None | Often used |
| macOS 14+ | Yes | Varies |
| CPU Usage | < 0.1% | Varies |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

MIT License -- see [LICENSE](LICENSE) for details.
