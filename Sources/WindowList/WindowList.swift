import CoreGraphics
import Foundation

/// One window, as reported by the window server.
public struct WindowInfo: Identifiable, Equatable, Sendable {
    public let id: CGWindowID
    public let title: String
    public let owner: String
    public let ownerPID: pid_t
    public let bounds: CGRect
    public let layer: Int
    /// False for minimized windows and windows of hidden apps.
    public let isOnScreen: Bool

    public init(
        id: CGWindowID,
        title: String,
        owner: String,
        ownerPID: pid_t,
        bounds: CGRect,
        layer: Int,
        isOnScreen: Bool = true
    ) {
        self.id = id
        self.title = title
        self.owner = owner
        self.ownerPID = ownerPID
        self.bounds = bounds
        self.layer = layer
        self.isOnScreen = isOnScreen
    }

    /// `nil` when the dictionary lacks the keys every real window has.
    public init?(dictionary: [String: Any]) {
        guard let id = dictionary[kCGWindowNumber as String] as? CGWindowID,
              let owner = dictionary[kCGWindowOwnerName as String] as? String,
              let pid = dictionary[kCGWindowOwnerPID as String] as? pid_t
        else { return nil }

        self.id = id
        self.owner = owner
        self.ownerPID = pid
        // Titles need Screen Recording, which this app does not ask for; the
        // Accessibility layer supplies titles where they are actually needed.
        self.title = dictionary[kCGWindowName as String] as? String ?? ""
        self.layer = dictionary[kCGWindowLayer as String] as? Int ?? 0
        // Key is simply absent for off-screen windows.
        self.isOnScreen = dictionary[kCGWindowIsOnscreen as String] as? Bool ?? false

        if let raw = dictionary[kCGWindowBounds as String] as? [String: Any],
           let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) {
            self.bounds = rect
        } else {
            self.bounds = .zero
        }
    }
}

/// Where the raw window dictionaries come from — swapped for a stub in tests.
public protocol WindowSource: Sendable {
    func windowDictionaries() -> [[String: Any]]
}

public struct CoreGraphicsWindowSource: WindowSource {
    public init() {}

    public func windowDictionaries() -> [[String: Any]] {
        // `.optionAll` rather than `.optionOnScreenOnly` so a window stays in the
        // list after it is minimized — otherwise its Show button would vanish.
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    }
}

public struct WindowLister: Sendable {
    private let source: WindowSource

    public init(source: WindowSource = CoreGraphicsWindowSource()) {
        self.source = source
    }

    /// Normal application windows (layer 0, non-empty frame), sorted by owner then title.
    public func listWindows() -> [WindowInfo] {
        source.windowDictionaries()
            .compactMap(WindowInfo.init(dictionary:))
            .filter { $0.layer == 0 && $0.bounds.width > 0 && $0.bounds.height > 0 }
            .sorted { ($0.owner.lowercased(), $0.title) < ($1.owner.lowercased(), $1.title) }
    }
}

