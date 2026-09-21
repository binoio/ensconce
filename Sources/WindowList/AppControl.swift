import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Ways to make an entire app disappear, cheapest and most standard first.
/// Each is verified against the window server, never by the API's return value:
/// some of these report success while doing nothing, and others report failure
/// or "unsupported" while having worked.
public enum AppHideStrategy: String, Sendable, Equatable, CaseIterable {
    /// NSRunningApplication.hide() — the real ⌘H. AppKit refuses it for
    /// accessory/agent apps (activation policy != .regular).
    case appHide
    /// AXHidden on the application element — the Accessibility route to ⌘H.
    /// Reaches accessory apps AppKit refuses, and unlike minimizing it leaves
    /// no Dock tile behind. Any already-minimized window must be restored
    /// first, because hiding an app does not clear an existing tile.
    case axHide
    /// System Events' `set visible to false`. A different code path that
    /// sometimes lands where AppKit's own hide will not. Needs Automation
    /// permission for System Events.
    case appleScript
    /// AXMinimized on every window of the app.
    case minimizeAll
    /// Park every window beyond all displays, remembering their frames.
    case offScreenAll

    public var label: String {
        switch self {
        case .appHide: return "hidden"
        case .axHide: return "hidden (AX)"
        case .appleScript: return "hidden via System Events"
        case .minimizeAll: return "minimized"
        case .offScreenAll: return "moved off-screen"
        }
    }
}

public enum AppHideState: Equatable, Sendable {
    case visible
    /// `nil` strategy: hidden by something other than us.
    case hidden(AppHideStrategy?)
    case unknown
}

public enum AppControlError: Error, Equatable {
    case appNotFound(pid: pid_t)
    case cannotHideSelf
    /// The only strategies that could reach this app need Accessibility.
    case accessibilityRequired(app: String)
    /// Every strategy ran and at least one window was still visible.
    case allStrategiesFailed(app: String, attempts: [AppHideStrategy])
    case restoreFailed(app: String)
    case freezeFailed(app: String, errno: Int32)
}

// MARK: - Collaborators

public protocol AppleScriptController {
    func setVisible(_ visible: Bool, pid: pid_t) throws
}

/// Drives System Events, which reaches some apps AppKit's hide() will not.
public struct SystemEventsController: AppleScriptController {
    public init() {}

    public func setVisible(_ visible: Bool, pid: pid_t) throws {
        let source = """
        tell application "System Events"
            set visible of (first process whose unix id is \(pid)) to \(visible)
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw AppleScriptFailure(info: error) }
    }

    public struct AppleScriptFailure: Error {
        public let info: NSDictionary
    }
}

/// Tier 2: freeze a hidden app so it cannot re-show itself.
public protocol ProcessController {
    func isFrozen(pid: pid_t) -> Bool
    func freeze(pid: pid_t) throws
    func resume(pid: pid_t) throws
}

public struct SignalProcessController: ProcessController {
    public init() {}

    /// Reads the kernel's process state rather than assuming our own signal stuck.
    public func isFrozen(pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &proc, &size, nil, 0) == 0, size > 0 else { return false }
        return proc.kp_proc.p_stat == SSTOP
    }

    public func freeze(pid: pid_t) throws { try signal(SIGSTOP, pid: pid) }
    public func resume(pid: pid_t) throws { try signal(SIGCONT, pid: pid) }

    private func signal(_ sig: Int32, pid: pid_t) throws {
        guard kill(pid, sig) == 0 else {
            throw AppControlError.freezeFailed(app: "pid \(pid)", errno: errno)
        }
    }
}

// MARK: - The hider

/// What was done to an app, so Show can undo exactly that.
struct AppHideRecord: Equatable {
    let strategy: AppHideStrategy
    /// Only used by .offScreenAll.
    let originalOrigins: [CGWindowID: CGPoint]
    let frozen: Bool
}

public final class AppHider {
    private let apps: RunningAppController
    private let ax: AXWindowController
    private let script: AppleScriptController
    private let processes: ProcessController
    private let probe: WindowVisibilityProbe
    private let selfPID: pid_t
    private let settleTimeout: TimeInterval
    private var records: [pid_t: AppHideRecord] = [:]

    public init(
        apps: RunningAppController = NSRunningApplicationController(),
        ax: AXWindowController = AccessibilityWindowController(),
        script: AppleScriptController = SystemEventsController(),
        processes: ProcessController = SignalProcessController(),
        probe: WindowVisibilityProbe = CoreGraphicsVisibilityProbe(),
        selfPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        settleTimeout: TimeInterval = 1.0
    ) {
        self.apps = apps
        self.ax = ax
        self.script = script
        self.processes = processes
        self.probe = probe
        self.selfPID = selfPID
        self.settleTimeout = settleTimeout
    }

    public func isSelf(_ app: AppInfo) -> Bool { app.pid == selfPID }

    public func isFrozen(_ app: AppInfo) -> Bool { processes.isFrozen(pid: app.pid) }

    public func state(of app: AppInfo) -> AppHideState {
        guard let appHidden = apps.isHidden(pid: app.pid) else { return .unknown }
        // A windowless app has no window server evidence to go on, so fall back
        // to what AppKit reports for the application itself.
        if app.windows.isEmpty { return appHidden ? .hidden(records[app.pid]?.strategy) : .visible }
        if anyWindowVisible(app) { return .visible }
        return .hidden(records[app.pid]?.strategy)
    }

    /// Runs each strategy until no window of the app is visible any more.
    /// `freeze` then SIGSTOPs the app so it cannot bring itself back.
    @discardableResult
    public func hide(_ app: AppInfo, freeze: Bool = false) throws -> AppHideStrategy {
        guard !isSelf(app) else { throw AppControlError.cannotHideSelf }
        guard apps.isHidden(pid: app.pid) != nil else { throw AppControlError.appNotFound(pid: app.pid) }

        // A frozen app cannot process a hide request; thaw first.
        if processes.isFrozen(pid: app.pid) { try? processes.resume(pid: app.pid) }

        var attempted: [AppHideStrategy] = []

        // 1. Real ⌘H — skipped for accessory apps, which AppKit always refuses.
        if app.isRegular {
            attempted.append(.appHide)
            apps.setHidden(true, pid: app.pid)
            if try finish(app, strategy: .appHide, origins: [:], freeze: freeze) { return .appHide }
            apps.setHidden(false, pid: app.pid)
        }

        // 2. AXHidden on the app element. Tried before minimizing because it
        //    leaves nothing in the Dock.
        guard ax.isTrusted() else { throw AppControlError.accessibilityRequired(app: app.name) }
        attempted.append(.axHide)
        // Hiding an app does not clear tiles for windows minimized earlier, so
        // bring those back first; undone below if this strategy does not take.
        let wasInvisible = app.windows.filter { !probe.isVisible(windowID: $0.id) }
        for window in wasInvisible { try? ax.setMinimized(false, for: window) }
        try? ax.setAppHidden(true, pid: app.pid)
        if try finish(app, strategy: .axHide, origins: [:], freeze: freeze) { return .axHide }
        try? ax.setAppHidden(false, pid: app.pid)
        for window in wasInvisible { try? ax.setMinimized(true, for: window) }

        // 3. System Events, which reaches some apps AppKit will not.
        attempted.append(.appleScript)
        try? script.setVisible(false, pid: app.pid)
        if try finish(app, strategy: .appleScript, origins: [:], freeze: freeze) { return .appleScript }
        try? script.setVisible(true, pid: app.pid)

        // 4. Minimize every window. Leaves a Dock tile, so it ranks below AXHidden.
        attempted.append(.minimizeAll)
        for window in app.windows { try? ax.setMinimized(true, for: window) }
        if try finish(app, strategy: .minimizeAll, origins: [:], freeze: freeze) { return .minimizeAll }
        for window in app.windows { try? ax.setMinimized(false, for: window) }

        // 5. Park every window beyond all displays.
        attempted.append(.offScreenAll)
        var origins: [CGWindowID: CGPoint] = [:]
        for window in app.windows {
            origins[window.id] = try? ax.origin(of: window)
            try? ax.setOrigin(parkingOrigin, for: window)
        }
        if try finish(app, strategy: .offScreenAll, origins: origins, freeze: freeze) { return .offScreenAll }
        for window in app.windows {
            if let origin = origins[window.id] { try? ax.setOrigin(origin, for: window) }
        }

        throw AppControlError.allStrategiesFailed(app: app.name, attempts: attempted)
    }

    public func show(_ app: AppInfo) throws {
        // Nothing below reaches a stopped process, so thaw before undoing.
        if processes.isFrozen(pid: app.pid) {
            try processes.resume(pid: app.pid)
        }

        let record = records[app.pid]
        switch record?.strategy {
        case .appHide:
            apps.setHidden(false, pid: app.pid)
        case .axHide:
            try? ax.setAppHidden(false, pid: app.pid)
        case .appleScript:
            try? script.setVisible(true, pid: app.pid)
        case .minimizeAll:
            for window in app.windows { try? ax.setMinimized(false, for: window) }
        case .offScreenAll:
            for window in app.windows {
                if let origin = record?.originalOrigins[window.id] {
                    try? ax.setOrigin(origin, for: window)
                }
            }
        case nil:
            // Hidden by something else, or before we launched: undo everything
            // plausible rather than guessing wrong.
            if apps.isHidden(pid: app.pid) == true { apps.setHidden(false, pid: app.pid) }
            try? ax.setAppHidden(false, pid: app.pid)
            try? script.setVisible(true, pid: app.pid)
            for window in app.windows { try? ax.setMinimized(false, for: window) }
        }

        guard settled(app, visible: true) else { throw AppControlError.restoreFailed(app: app.name) }
        records[app.pid] = nil
    }

    public func toggle(_ app: AppInfo, freeze: Bool = false) throws {
        switch state(of: app) {
        case .hidden: try show(app)
        case .visible: try hide(app, freeze: freeze)
        case .unknown: throw AppControlError.appNotFound(pid: app.pid)
        }
    }

    // MARK: Private

    /// Records the strategy and applies the optional freeze, if it worked.
    private func finish(
        _ app: AppInfo,
        strategy: AppHideStrategy,
        origins: [CGWindowID: CGPoint],
        freeze: Bool
    ) throws -> Bool {
        guard settled(app, visible: false) else { return false }
        var froze = false
        if freeze {
            do {
                try processes.freeze(pid: app.pid)
                froze = true
            } catch {
                // The app is hidden either way; report the freeze failure but
                // keep the record honest about not having frozen it.
                records[app.pid] = AppHideRecord(strategy: strategy, originalOrigins: origins, frozen: false)
                throw AppControlError.freezeFailed(app: app.name, errno: errno)
            }
        }
        records[app.pid] = AppHideRecord(strategy: strategy, originalOrigins: origins, frozen: froze)
        return true
    }

    private func anyWindowVisible(_ app: AppInfo) -> Bool {
        app.windows.contains { probe.isVisible(windowID: $0.id) }
    }

    private func settled(_ app: AppInfo, visible: Bool) -> Bool {
        guard !app.windows.isEmpty else {
            return pollUntil(timeout: settleTimeout) { self.apps.isHidden(pid: app.pid) == !visible }
        }
        return pollUntil(timeout: settleTimeout) { self.anyWindowVisible(app) == visible }
    }
}
