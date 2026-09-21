import AppKit
import Combine
import Sparkle
import SwiftUI

/// Owns the Sparkle updater. Started manually, and only from a real bundle
/// with a feed configured, so `swift run` and xctest never schedule checks.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    lazy var updater = UpdaterViewModel(updater: updaterController.updater)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updaterController.startUpdater()
        }
    }
}

/// Bridges SPUUpdater's KVO-driven and persisted state into SwiftUI. Sparkle
/// persists the automatic check/download preferences itself.
final class UpdaterViewModel: ObservableObject {
    let updater: SPUUpdater
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() { updater.checkForUpdates() }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}

struct UpdatesSection: View {
    @ObservedObject var updater: UpdaterViewModel

    var body: some View {
        Section("Updates") {
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.automaticallyChecksForUpdates = $0 }
            ))
            Toggle("Automatically download updates", isOn: Binding(
                get: { updater.automaticallyDownloadsUpdates },
                set: { updater.automaticallyDownloadsUpdates = $0 }
            ))
            .disabled(!updater.automaticallyChecksForUpdates)

            if let lastCheck = updater.lastUpdateCheckDate {
                Text("Last checked: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            CheckForUpdatesButton(updater: updater)
        }
    }
}
