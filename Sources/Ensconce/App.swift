import SwiftUI
import WindowList

/// Shared between the window and the View menu, and remembered across launches.
enum Prefs {
    static let showAllApps = "showAllApps"
    static let showDetails = "showDetails"
    static let showSystemProcesses = "showSystemProcesses"
    static let freezeWhenHidden = "freezeWhenHidden"
}

/// The highlighted row of the front window, published so the File menu can
/// act on it.
struct SelectedAppKey: FocusedValueKey {
    typealias Value = AppInfo
}

extension FocusedValues {
    var selectedApp: AppInfo? {
        get { self[SelectedAppKey.self] }
        set { self[SelectedAppKey.self] = newValue }
    }
}

enum WindowID {
    static let info = "info"
}

@main
struct EnsconceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @AppStorage(Prefs.showAllApps) private var showAllApps = false
    @AppStorage(Prefs.showDetails) private var showDetails = false
    @AppStorage(Prefs.showSystemProcesses) private var showSystemProcesses = false

    var body: some Scene {
        WindowGroup("Apps") {
            ContentView()
        }
        .defaultSize(width: 560, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: appDelegate.updater)
            }
            CommandGroup(after: .newItem) {
                GetInfoButton()
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Toggle("Show All Detected Apps", isOn: $showAllApps)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Toggle("Show App Details", isOn: $showDetails)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Toggle("Show System Processes", isOn: $showSystemProcesses)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
            }
        }

        // One Info window per process; opening the same pid again brings it forward.
        WindowGroup("Info", id: WindowID.info, for: pid_t.self) { $pid in
            if let pid {
                ProcessInfoView(pid: pid)
            }
        }
        .defaultSize(width: 480, height: 440)

        Settings {
            SettingsView(updater: appDelegate.updater)
        }
    }
}

struct GetInfoButton: View {
    @FocusedValue(\.selectedApp) private var selectedApp
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Get Info") {
            if let selectedApp { openWindow(id: WindowID.info, value: selectedApp.pid) }
        }
        .keyboardShortcut("i", modifiers: .command)
        .disabled(selectedApp == nil)
    }
}

struct ContentView: View {
    private let lister = AppLister()
    private let hider = AppHider()
    private let dock = AXDockController()
    private let ax = AccessibilityWindowController()

    @AppStorage(Prefs.showAllApps) private var showAllApps = false
    @AppStorage(Prefs.showDetails) private var showDetails = false
    @AppStorage(Prefs.showSystemProcesses) private var showSystemProcesses = false
    @AppStorage(Prefs.freezeWhenHidden) private var freezeWhenHidden = false

    @Environment(\.openWindow) private var openWindow

    @State private var apps: [AppInfo] = []
    @State private var selectedPID: pid_t?
    @State private var dockTiles: Set<String> = []
    @State private var errorMessage: String?

    private var selectedApp: AppInfo? {
        apps.first { $0.pid == selectedPID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            List(apps, selection: $selectedPID) { app in
                row(for: app)
                    .contextMenu {
                        Button("Get Info") { openWindow(id: WindowID.info, value: app.pid) }
                    }
            }
        }
        .navigationTitle(showAllApps ? "All Apps (\(apps.count))" : "Apps with Windows (\(apps.count))")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
        }
        .focusedSceneValue(\.selectedApp, selectedApp)
        .onAppear {
            Diagnostics.log()
            refresh()
        }
        .onChange(of: showAllApps) { _, _ in refresh() }
        .onChange(of: showSystemProcesses) { _, _ in refresh() }
    }

    private func row(for app: AppInfo) -> some View {
        let state = hider.state(of: app)
        let isHidden = if case .hidden = state { true } else { false }
        let hiddenBy: AppHideStrategy? = if case .hidden(let strategy) = state { strategy } else { nil }

        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.body)
                        .foregroundStyle(isHidden ? .secondary : .primary)
                    if isHidden { tag(hiddenBy?.label ?? "hidden") }
                    if hider.isFrozen(app) { tag("frozen") }
                    if hasDockTile(app) { tag("in Dock") }
                    if app.isSystem { tag("system") }
                }
                if showDetails {
                    Text(details(for: app))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Button(isHidden ? "Show" : "Hide") {
                toggle(app)
            }
            .disabled(state == .unknown || hider.isSelf(app))
            .help(hider.isSelf(app) ? "This is Ensconce itself." : "")
        }
        .padding(.vertical, 3)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.secondary.opacity(0.18), in: Capsule())
    }

    private func details(for app: AppInfo) -> String {
        let count = app.windows.count
        return "pid \(app.pid) · \(count) window\(count == 1 ? "" : "s") · \(app.isRegular ? "app" : "agent")"
    }

    /// A minimized window keeps a Dock tile even once its app is hidden. Titles
    /// come from Accessibility, since this app does not ask for Screen Recording.
    private func hasDockTile(_ app: AppInfo) -> Bool {
        guard !dockTiles.isEmpty else { return false }
        return ax.windowTitles(pid: app.pid).contains { dockTiles.contains($0) }
    }

    private func toggle(_ app: AppInfo) {
        do {
            try hider.toggle(app, freeze: freezeWhenHidden)
            errorMessage = nil
        } catch let error as AppControlError {
            errorMessage = describe(error)
        } catch {
            errorMessage = "Hide/Show failed: \(error)"
        }
        refresh()
    }

    private func describe(_ error: AppControlError) -> String {
        switch error {
        case .appNotFound(let pid):
            return "That app (pid \(pid)) is no longer running."
        case .cannotHideSelf:
            return "Ensconce can't hide itself — you'd lose the button to bring it back."
        case .accessibilityRequired(let app):
            return "\(app) is an agent app — hiding it needs Accessibility permission. "
                + "Grant it in Settings → Permissions (⌘,), then relaunch Ensconce."
        case .allStrategiesFailed(let app, let attempts):
            return "\(app) resisted every hide method (tried: \(attempts.map(\.rawValue).joined(separator: ", ")))."
        case .restoreFailed(let app):
            return "Couldn't bring \(app) back — it may have closed its windows."
        case .freezeFailed(let app, let code):
            return "\(app) was hidden, but freezing it failed (errno \(code))."
        }
    }

    private func refresh() {
        apps = lister.listApps(includeWindowless: showAllApps, includeSystem: showSystemProcesses)
        dockTiles = dock.minimizedTileTitles()
        if let selectedPID, !apps.contains(where: { $0.pid == selectedPID }) {
            self.selectedPID = nil
        }
    }
}

struct SettingsView: View {
    private let loginItem = SMAppServiceLoginItem()
    @ObservedObject var updater: UpdaterViewModel

    @AppStorage(Prefs.freezeWhenHidden) private var freezeWhenHidden = false
    @State private var openAtLogin = false
    @State private var loginNote: String?
    @State private var accessibilityGranted = hasAccessibilityPermission()

    var body: some View {
        Form {
            Section("General") {
                Toggle("Automatically open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, newValue in setOpenAtLogin(newValue) }
                if let loginNote {
                    Text(loginNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hiding") {
                Toggle("Freeze apps when hiding them", isOn: $freezeWhenHidden)
                Text("Sends SIGSTOP after a verified hide, so an app can't bring itself back. "
                     + "Show resumes it. Frozen apps do no background work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack(spacing: 8) {
                        Text(accessibilityGranted ? "Granted" : "Not granted")
                            .foregroundStyle(accessibilityGranted ? Color.secondary : Color.orange)
                        Button(accessibilityGranted ? "Open System Settings…" : "Grant…") {
                            requestAccessibilityPermission()
                            refreshPermissions()
                        }
                    }
                }
                Text("Needed to hide agent apps, minimize stubborn windows, and read Dock tiles. "
                     + "Regular apps hide without it. Grants are tied to the code signature, so an "
                     + "ad-hoc build loses them on every rebuild.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            UpdatesSection(updater: updater)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            syncLoginItem()
            refreshPermissions()
        }
        // Re-check when coming back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissions()
        }
    }

    private func refreshPermissions() {
        accessibilityGranted = hasAccessibilityPermission()
    }

    private func syncLoginItem() {
        let status = loginItem.status()
        openAtLogin = status == .enabled
        loginNote = switch status {
        case .requiresApproval: "Approve Ensconce in System Settings → General → Login Items."
        case .unavailable: "Unavailable here — launchd won't register an app running from "
            + "this location. Move Ensconce.app to /Applications and relaunch."
        default: nil
        }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginNote = nil
        } catch {
            loginNote = "Couldn't \(enabled ? "enable" : "disable") open at login: \(error.localizedDescription)"
        }
        // Report what the system actually holds, not what was asked for.
        syncLoginItem()
    }
}
