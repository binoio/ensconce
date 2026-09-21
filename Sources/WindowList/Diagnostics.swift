import AppKit
import ApplicationServices
import Foundation

/// Why a hide failed is almost always a permission or code-signing fact rather
/// than anything about the target app, and a GUI app cannot be asked from a
/// terminal — so it records what it can see about itself on launch.
public struct Diagnostics {
    public static var logURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Ensconce.log")
    }

    public static func report() -> String {
        let bundle = Bundle.main
        return """
        Ensconce diagnostics \(ISO8601DateFormatter().string(from: Date()))
          pid:                \(ProcessInfo.processInfo.processIdentifier)
          bundle path:        \(bundle.bundlePath)
          bundle id:          \(bundle.bundleIdentifier ?? "(none)")
          accessibility:      \(AXIsProcessTrusted())
          open at login:      \(SMAppServiceLoginItem().status())
          apps with windows:  \(AppLister().listApps().count)
          apps detected:      \(AppLister().listApps(includeWindowless: true, includeSystem: true).count)
        """
    }

    public static func log() {
        let line = report() + "\n\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
