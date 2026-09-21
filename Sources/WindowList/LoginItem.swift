import Foundation
import ServiceManagement

/// "Open at login", backed by SMAppService. Registration can be refused (an
/// unsigned or ad-hoc build, or a pending user approval), so the caller is
/// told rather than left with a switch that silently does nothing.
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but the user still has to approve it in System Settings.
    case requiresApproval
    case unavailable
}

public protocol LoginItemController {
    func status() -> LoginItemStatus
    func setEnabled(_ enabled: Bool) throws
}

public struct SMAppServiceLoginItem: LoginItemController {
    public init() {}

    public func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
