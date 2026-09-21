import AppKit
import CoreGraphics
import Foundation
@testable import WindowList

/// A fake desktop. Every double below drives this one visibility model, so a
/// strategy only "works" if it changes what the window server would show —
/// the same rule the real code lives by.
final class FakeDesktop {
    var visibleWindows: Set<CGWindowID>
    var appHidden = false
    var frozenPIDs: Set<pid_t> = []

    init(visible: Set<CGWindowID> = [1]) {
        self.visibleWindows = visible
    }
}

func testWindow(id: CGWindowID = 1, pid: pid_t = 100, title: String = "Doc") -> WindowInfo {
    WindowInfo(
        id: id,
        title: title,
        owner: "TextEdit",
        ownerPID: pid,
        bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
        layer: 0,
        isOnScreen: true
    )
}

func testApp(pid: pid_t = 100, regular: Bool = true, windowIDs: [CGWindowID] = [1]) -> AppInfo {
    AppInfo(
        pid: pid,
        name: "TextEdit",
        bundleID: "com.apple.TextEdit",
        isRegular: regular,
        windows: windowIDs.map { testWindow(id: $0, pid: pid) }
    )
}

final class MockApps: RunningAppController {
    let desktop: FakeDesktop
    var knownPIDs: Set<pid_t>
    var regular: Set<pid_t>
    var executables: [pid_t: String] = [:]
    /// Mimics AppKit accepting the call while nothing changes on screen.
    var hideSilentlyFails = false
    private(set) var setCalls: [(Bool, pid_t)] = []

    init(desktop: FakeDesktop, knownPIDs: Set<pid_t> = [100], regular: Set<pid_t> = [100]) {
        self.desktop = desktop
        self.knownPIDs = knownPIDs
        self.regular = regular
    }

    func isHidden(pid: pid_t) -> Bool? { knownPIDs.contains(pid) ? desktop.appHidden : nil }
    func isRegularApp(pid: pid_t) -> Bool { regular.contains(pid) }
    func bundleID(pid: pid_t) -> String? { knownPIDs.contains(pid) ? "com.example.\(pid)" : nil }
    func localizedName(pid: pid_t) -> String? { knownPIDs.contains(pid) ? "App \(pid)" : nil }
    func executablePath(pid: pid_t) -> String? { executables[pid] }

    func setHidden(_ hide: Bool, pid: pid_t) {
        guard knownPIDs.contains(pid) else { return }
        setCalls.append((hide, pid))
        guard !hideSilentlyFails else { return }
        desktop.appHidden = hide
        setAllWindows(visible: !hide)
    }

    private func setAllWindows(visible: Bool) {
        if visible { desktop.visibleWindows = [1, 2, 3] } else { desktop.visibleWindows = [] }
    }
}

final class MockProbe: WindowVisibilityProbe {
    let desktop: FakeDesktop
    init(desktop: FakeDesktop) { self.desktop = desktop }
    func isVisible(windowID: CGWindowID) -> Bool { desktop.visibleWindows.contains(windowID) }
}

/// Models AX support per capability, including the real behaviours seen in the
/// wild: "reports success, changes nothing", and a settable-but-unreadable
/// AXMinimized.
class MockAX: AXWindowController {
    let desktop: FakeDesktop
    var trusted = true
    var minimizedSupported = true
    var moveSupported = true
    var appHideSupported = false
    private(set) var appHideCalls: [(pid_t, Bool)] = []
    var origins: [CGWindowID: CGPoint] = [:]
    private(set) var minimizeCalls: [(CGWindowID, Bool)] = []
    private(set) var originCalls: [(CGWindowID, CGPoint)] = []

    init(desktop: FakeDesktop) { self.desktop = desktop }

    func isTrusted() -> Bool { trusted }

    func setMinimized(_ value: Bool, for window: WindowInfo) throws {
        guard trusted else { throw WindowControlError.accessibilityNotTrusted }
        record(minimize: window.id, value)
        guard minimizedSupported else { return }
        setVisible(!value, window.id)
    }

    var titles: [pid_t: [String]] = [:]

    func windowTitles(pid: pid_t) -> [String] { titles[pid] ?? [] }

    func setAppHidden(_ hidden: Bool, pid: pid_t) throws {
        guard trusted else { throw WindowControlError.accessibilityNotTrusted }
        appHideCalls.append((pid, hidden))
        guard appHideSupported else { return }
        desktop.visibleWindows = hidden ? [] : [1, 2, 3]
    }

    func origin(of window: WindowInfo) throws -> CGPoint {
        guard trusted else { throw WindowControlError.accessibilityNotTrusted }
        return origins[window.id] ?? CGPoint(x: 10, y: 20)
    }

    func setOrigin(_ origin: CGPoint, for window: WindowInfo) throws {
        guard trusted else { throw WindowControlError.accessibilityNotTrusted }
        originCalls.append((window.id, origin))
        guard moveSupported else { return }
        origins[window.id] = origin
        setVisible(origin != parkingOrigin, window.id)
    }

    func record(minimize id: CGWindowID, _ value: Bool) {
        minimizeCalls.append((id, value))
    }

    func setVisible(_ visible: Bool, _ id: CGWindowID) {
        if visible { desktop.visibleWindows.insert(id) } else { desktop.visibleWindows.remove(id) }
    }
}

final class MockScript: AppleScriptController {
    let desktop: FakeDesktop
    var supported = false
    private(set) var calls: [(pid_t, Bool)] = []

    init(desktop: FakeDesktop) { self.desktop = desktop }

    func setVisible(_ visible: Bool, pid: pid_t) throws {
        calls.append((pid, visible))
        guard supported else { throw WindowControlError.windowNotFound }
        desktop.visibleWindows = visible ? [1, 2, 3] : []
    }
}

final class MockProcesses: ProcessController {
    let desktop: FakeDesktop
    var freezeFails = false
    private(set) var calls: [String] = []

    init(desktop: FakeDesktop) { self.desktop = desktop }

    func isFrozen(pid: pid_t) -> Bool { desktop.frozenPIDs.contains(pid) }

    func freeze(pid: pid_t) throws {
        calls.append("freeze(\(pid))")
        if freezeFails { throw AppControlError.freezeFailed(app: "TextEdit", errno: 1) }
        desktop.frozenPIDs.insert(pid)
    }

    func resume(pid: pid_t) throws {
        calls.append("resume(\(pid))")
        desktop.frozenPIDs.remove(pid)
    }
}

func makeHider(
    desktop: FakeDesktop,
    apps: MockApps,
    ax: MockAX,
    script: MockScript? = nil,
    processes: MockProcesses? = nil,
    selfPID: pid_t = 999
) -> AppHider {
    AppHider(
        apps: apps,
        ax: ax,
        script: script ?? MockScript(desktop: desktop),
        processes: processes ?? MockProcesses(desktop: desktop),
        probe: MockProbe(desktop: desktop),
        selfPID: selfPID,
        settleTimeout: 0.05
    )
}
