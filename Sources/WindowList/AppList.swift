import AppKit
import CoreGraphics
import Foundation

/// A running application with on-screen windows — the unit the UI works in.
public struct AppInfo: Identifiable, Equatable, Sendable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    /// False for accessory/agent apps, which AppKit refuses to hide.
    public let isRegular: Bool
    /// True for macOS's own helpers — loginwindow, XPC view services, WebKit
    /// content processes — which are noise unless you are hunting one down.
    public let isSystem: Bool
    public let executablePath: String?
    public let windows: [WindowInfo]

    public init(
        pid: pid_t, name: String, bundleID: String?, isRegular: Bool, isSystem: Bool = false,
        executablePath: String? = nil, windows: [WindowInfo]
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.isRegular = isRegular
        self.isSystem = isSystem
        self.executablePath = executablePath
        self.windows = windows
    }

    /// A system process is a non-regular app whose executable ships with the
    /// OS. Regular apps are exempt so Finder (in CoreServices) and everything
    /// in /System/Applications stay listed. Cryptex mounts put OS frameworks
    /// under /System/Volumes/Preboot/Cryptexes, which the /System/ prefix
    /// covers; /System/Volumes/Data is the user's own volume and is not.
    public static func isSystemProcess(executablePath: String?, isRegular: Bool) -> Bool {
        guard !isRegular, let path = executablePath else { return false }
        if path.hasPrefix("/System/Volumes/Data/") { return false }
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/")
    }

    public var windowTitles: [String] {
        windows.map { $0.title.isEmpty ? "(untitled)" : $0.title }
    }
}

/// One running application as AppKit reports it, windows or not.
public struct RunningAppSnapshot: Equatable, Sendable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    public let isRegular: Bool
    public let executablePath: String?

    public init(pid: pid_t, name: String, bundleID: String?, isRegular: Bool, executablePath: String? = nil) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.isRegular = isRegular
        self.executablePath = executablePath
    }

    public var isSystem: Bool {
        AppInfo.isSystemProcess(executablePath: executablePath, isRegular: isRegular)
    }
}

public protocol RunningAppsProvider: Sendable {
    func allApps() -> [RunningAppSnapshot]
}

public struct NSWorkspaceAppsProvider: RunningAppsProvider {
    public init() {}

    public func allApps() -> [RunningAppSnapshot] {
        NSWorkspace.shared.runningApplications.map {
            RunningAppSnapshot(
                pid: $0.processIdentifier,
                name: $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)",
                bundleID: $0.bundleIdentifier,
                isRegular: $0.activationPolicy == .regular,
                executablePath: $0.executableURL?.path
            )
        }
    }
}

public struct AppLister {
    private let windows: WindowLister
    private let apps: RunningAppController
    private let provider: RunningAppsProvider

    public init(
        windows: WindowLister = WindowLister(),
        apps: RunningAppController = NSRunningApplicationController(),
        provider: RunningAppsProvider = NSWorkspaceAppsProvider()
    ) {
        self.windows = windows
        self.apps = apps
        self.provider = provider
    }

    /// By default, one entry per process that owns at least one normal window.
    /// `includeWindowless` adds every other running app AppKit knows about;
    /// `includeSystem` keeps the OS's own helper processes in the list.
    public func listApps(includeWindowless: Bool = false, includeSystem: Bool = false) -> [AppInfo] {
        let grouped = Dictionary(grouping: windows.listWindows(), by: \.ownerPID)
        var listed = grouped.map { pid, windows in
            let isRegular = apps.isRegularApp(pid: pid)
            let executable = apps.executablePath(pid: pid)
            return AppInfo(
                pid: pid,
                name: apps.localizedName(pid: pid) ?? windows[0].owner,
                bundleID: apps.bundleID(pid: pid),
                isRegular: isRegular,
                isSystem: AppInfo.isSystemProcess(executablePath: executable, isRegular: isRegular),
                executablePath: executable,
                windows: windows.sorted { $0.title < $1.title }
            )
        }

        if includeWindowless {
            let withWindows = Set(listed.map(\.pid))
            listed += provider.allApps()
                .filter { !withWindows.contains($0.pid) }
                .map {
                    AppInfo(pid: $0.pid, name: $0.name, bundleID: $0.bundleID, isRegular: $0.isRegular,
                            isSystem: $0.isSystem, executablePath: $0.executablePath, windows: [])
                }
        }

        if !includeSystem {
            listed.removeAll(where: \.isSystem)
        }

        return listed.sorted { ($0.name.lowercased(), $0.pid) < ($1.name.lowercased(), $1.pid) }
    }
}
