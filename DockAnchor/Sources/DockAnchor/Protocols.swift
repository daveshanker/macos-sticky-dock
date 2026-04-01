import AppKit
import CoreGraphics

// MARK: - DisplayInfo

/// Represents a connected display.
struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let frame: CGRect

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - DisplayProviding

/// Enumerate screens, identify which has Dock.
@MainActor
protocol DisplayProviding: AnyObject {
    var connectedDisplays: [DisplayInfo] { get }
    var dockDisplayID: CGDirectDisplayID? { get }
    var onDisplaysChanged: (([DisplayInfo]) -> Void)? { get set }
    func startObserving()
    func stopObserving()
    func displayInfo(for id: CGDirectDisplayID) -> DisplayInfo?
}

// MARK: - PreferencesPersisting

/// Read/write home display preference and other settings.
protocol PreferencesPersisting: AnyObject {
    var preferredDisplayID: CGDirectDisplayID? { get set }
    var launchAtLogin: Bool { get set }
}
