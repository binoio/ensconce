import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Errors from the Accessibility layer itself; app-level failures are in AppControlError.
public enum WindowControlError: Error, Equatable {
    case accessibilityNotTrusted
    case windowNotFound
}

// MARK: - Ground truth: is this window actually visible?

public protocol WindowVisibilityProbe: Sendable {
    /// True only when the window is ordered in *and* overlaps a display —
    /// minimized, app-hidden and parked windows all read false.
    func isVisible(windowID: CGWindowID) -> Bool
}

public struct CoreGraphicsVisibilityProbe: WindowVisibilityProbe {
    public init() {}

    public func isVisible(windowID: CGWindowID) -> Bool {
        // CGWindowListCreateDescriptionFromArray comes back empty for windows
        // that are plainly present, so query the list by id instead.
        guard let raw = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let entry = raw.first
        else { return false }

        guard entry[kCGWindowIsOnscreen as String] as? Bool == true else { return false }
        guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return false }

        return Self.displayBounds().contains { $0.intersects(bounds) }
    }

    /// Display frames in CoreGraphics' top-left origin space, matching kCGWindowBounds.
    static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map(CGDisplayBounds)
    }
}

// MARK: - Application-level control

public protocol RunningAppController {
    func isHidden(pid: pid_t) -> Bool?
    func isRegularApp(pid: pid_t) -> Bool
    func bundleID(pid: pid_t) -> String?
    func localizedName(pid: pid_t) -> String?
    func executablePath(pid: pid_t) -> String?
    func setHidden(_ hidden: Bool, pid: pid_t)
}

public struct NSRunningApplicationController: RunningAppController {
    public init() {}

    public func isHidden(pid: pid_t) -> Bool? {
        NSRunningApplication(processIdentifier: pid)?.isHidden
    }

    public func isRegularApp(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }

    public func bundleID(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    public func localizedName(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    public func executablePath(pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.executableURL?.path
    }

    public func setHidden(_ hidden: Bool, pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        _ = hidden ? app.hide() : app.unhide()
    }
}

// MARK: - Accessibility window control

/// A window as the Accessibility API sees it — the half we can match against.
public struct AXWindowSnapshot: Equatable, Sendable {
    public let title: String
    public let frame: CGRect

    public init(title: String, frame: CGRect) {
        self.title = title
        self.frame = frame
    }
}

/// Picks the Accessibility window corresponding to a CoreGraphics window; the
/// two APIs share no public identifier, so match on title, then frame.
public func matchIndex(
    of window: WindowInfo,
    among candidates: [AXWindowSnapshot],
    tolerance: CGFloat = 2
) -> Int? {
    if !window.title.isEmpty {
        let titled = candidates.indices.filter { candidates[$0].title == window.title }
        if titled.count == 1 { return titled[0] }
        if titled.count > 1 {
            return titled.first { framesMatch(candidates[$0].frame, window.bounds, tolerance) }
        }
    }
    let framed = candidates.indices.filter { framesMatch(candidates[$0].frame, window.bounds, tolerance) }
    return framed.count == 1 ? framed[0] : nil
}

private func framesMatch(_ lhs: CGRect, _ rhs: CGRect, _ tolerance: CGFloat) -> Bool {
    abs(lhs.origin.x - rhs.origin.x) <= tolerance
        && abs(lhs.origin.y - rhs.origin.y) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

public protocol AXWindowController {
    func isTrusted() -> Bool
    func setMinimized(_ minimized: Bool, for window: WindowInfo) throws
    func origin(of window: WindowInfo) throws -> CGPoint
    func setOrigin(_ origin: CGPoint, for window: WindowInfo) throws
    /// AXHidden on the *application* element — the AX route to ⌘H, which
    /// reaches accessory apps that NSRunningApplication.hide() refuses.
    func setAppHidden(_ hidden: Bool, pid: pid_t) throws
    /// Window titles straight from Accessibility. CoreGraphics only supplies
    /// these with Screen Recording permission, which this app does not need.
    func windowTitles(pid: pid_t) -> [String]
}

public struct AccessibilityWindowController: AXWindowController {
    public init() {}

    public func isTrusted() -> Bool { AXIsProcessTrusted() }

    public func setMinimized(_ minimized: Bool, for window: WindowInfo) throws {
        // Deliberately ignores the return code: apps exist whose AXMinimized is
        // settable but unreadable, and they report errors on a working set.
        AXUIElementSetAttributeValue(
            try element(for: window),
            kAXMinimizedAttribute as CFString,
            minimized as CFBoolean
        )
    }

    public func setAppHidden(_ hidden: Bool, pid: pid_t) throws {
        guard AXIsProcessTrusted() else { throw WindowControlError.accessibilityNotTrusted }
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXHiddenAttribute as CFString,
            hidden as CFBoolean
        )
    }

    public func windowTitles(pid: pid_t) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXWindowsAttribute as CFString,
            &value
        )
        return (value as? [AXUIElement] ?? []).compactMap { element in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            return title as? String
        }
    }

    public func origin(of window: WindowInfo) throws -> CGPoint {
        try readOrigin(of: try element(for: window))
    }

    public func setOrigin(_ origin: CGPoint, for window: WindowInfo) throws {
        var mutable = origin
        guard let value = AXValueCreate(.cgPoint, &mutable) else { throw WindowControlError.windowNotFound }
        AXUIElementSetAttributeValue(try element(for: window), kAXPositionAttribute as CFString, value)
    }

    // MARK: Private

    private func element(for window: WindowInfo) throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw WindowControlError.accessibilityNotTrusted }

        let app = AXUIElementCreateApplication(window.ownerPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement], !axWindows.isEmpty
        else { throw WindowControlError.windowNotFound }

        if axWindows.count == 1 { return axWindows[0] }
        guard let index = matchIndex(of: window, among: axWindows.map(snapshot(of:))) else {
            throw WindowControlError.windowNotFound
        }
        return axWindows[index]
    }

    private func readOrigin(of element: AXUIElement) throws -> CGPoint {
        var origin = CGPoint.zero
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value
        else { throw WindowControlError.windowNotFound }
        AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        return origin
    }

    private func snapshot(of element: AXUIElement) -> AXWindowSnapshot {
        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)

        var size = CGSize.zero
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let sizeValue {
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        }
        return AXWindowSnapshot(
            title: titleValue as? String ?? "",
            frame: CGRect(origin: (try? readOrigin(of: element)) ?? .zero, size: size)
        )
    }
}

/// Somewhere no display reaches, for the off-screen strategy.
public let parkingOrigin = CGPoint(x: -40000, y: -40000)

public func hasAccessibilityPermission() -> Bool { AXIsProcessTrusted() }

/// Prompts for Accessibility permission, opening System Settings if needed.
public func requestAccessibilityPermission() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

func pollUntil(timeout: TimeInterval, step: TimeInterval = 0.05, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: step)
    } while Date() < deadline
    return condition()
}

// MARK: - Dock tiles

/// A minimized window leaves a tile in the Dock even once its app is hidden,
/// so "gone from view" and "gone from the Dock" are separate questions.
public protocol DockController {
    func minimizedTileTitles() -> Set<String>
}

public struct AXDockController: DockController {
    public init() {}

    public func minimizedTileTitles() -> Set<String> {
        guard AXIsProcessTrusted(),
              let dockPID = NSRunningApplication
                  .runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        else { return [] }

        let dock = AXUIElementCreateApplication(dockPID)
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(dock, kAXChildrenAttribute as CFString, &children)
        guard let list = (children as? [AXUIElement])?.first else { return [] }

        var items: CFTypeRef?
        AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items)

        var titles: Set<String> = []
        for item in items as? [AXUIElement] ?? [] {
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXSubroleAttribute as CFString, &subrole)
            guard subrole as? String == "AXMinimizedWindowDockItem" else { continue }
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &title)
            if let title = title as? String { titles.insert(title) }
        }
        return titles
    }
}
