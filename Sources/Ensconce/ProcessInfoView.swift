import SwiftUI
import WindowList

/// File → Get Info for the highlighted row. Reads the process fresh each time,
/// including windowless and system entries, since the list may be filtering
/// the very process the user asked about.
struct ProcessInfoView: View {
    let pid: pid_t

    private let lister = AppLister()
    private let hider = AppHider()
    private let ax = AccessibilityWindowController()

    @State private var app: AppInfo?
    @State private var state: AppHideState = .unknown
    @State private var frozen = false
    @State private var axTitles: [String] = []

    var body: some View {
        Group {
            if let app {
                Form {
                    Section("Process") {
                        LabeledContent("Name", value: app.name)
                        LabeledContent("PID", value: String(app.pid))
                        LabeledContent("Bundle ID", value: app.bundleID ?? "—")
                        LabeledContent("Kind", value: kind(app))
                        LabeledContent("Executable") {
                            Text(app.executablePath ?? "—")
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Section("State") {
                        LabeledContent("Visibility", value: visibility)
                        LabeledContent("Frozen", value: frozen ? "Yes (SIGSTOP)" : "No")
                    }
                    // CoreGraphics only reveals titles with Screen Recording, which
                    // Ensconce never requests; Accessibility supplies them instead.
                    if !axTitles.isEmpty {
                        Section("Titles") {
                            ForEach(axTitles, id: \.self) { Text($0) }
                        }
                    }
                    Section("Windows (\(app.windows.count))") {
                        if app.windows.isEmpty {
                            Text("No windows").foregroundStyle(.secondary)
                        }
                        ForEach(app.windows) { window in
                            LabeledContent(window.title.isEmpty ? "#\(window.id)" : window.title) {
                                Text(describe(window))
                                    .foregroundStyle(.secondary)
                                    .font(.callout.monospacedDigit())
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView(
                    "Process \(pid) is no longer running",
                    systemImage: "xmark.circle"
                )
            }
        }
        .navigationTitle(app.map { "\($0.name) Info" } ?? "Info")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
        }
        .onAppear(perform: refresh)
        .frame(minWidth: 420, minHeight: 360)
    }

    private var visibility: String {
        switch state {
        case .visible: "Visible"
        case .hidden(let strategy): strategy.map { "Hidden (\($0.label))" } ?? "Hidden"
        case .unknown: "Unknown"
        }
    }

    private func kind(_ app: AppInfo) -> String {
        if app.isSystem { return "System process" }
        return app.isRegular ? "Regular app" : "Agent (accessory or background)"
    }

    private func describe(_ window: WindowInfo) -> String {
        let b = window.bounds
        let size = "\(Int(b.width))×\(Int(b.height)) at (\(Int(b.minX)), \(Int(b.minY)))"
        return window.isOnScreen ? size : "\(size) · off screen"
    }

    private func refresh() {
        app = lister.listApps(includeWindowless: true, includeSystem: true).first { $0.pid == pid }
        if let app {
            state = hider.state(of: app)
            frozen = hider.isFrozen(app)
            axTitles = ax.windowTitles(pid: app.pid).filter { !$0.isEmpty }
        }
    }
}
