import XCTest
@testable import WindowList

/// Records what was asked for, and can refuse the way an unsigned build does.
private final class MockLoginItem: LoginItemController {
    var current: LoginItemStatus = .disabled
    var failure: Error?
    private(set) var calls: [Bool] = []

    func status() -> LoginItemStatus { current }

    func setEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if let failure { throw failure }
        current = enabled ? .enabled : .disabled
    }
}

private struct RefusedRegistration: Error {}

final class LoginItemTests: XCTestCase {
    func testDefaultIsDisabled() {
        XCTAssertEqual(MockLoginItem().status(), .disabled)
    }

    func testEnablingAndDisablingRoundTrips() throws {
        let item = MockLoginItem()
        try item.setEnabled(true)
        XCTAssertEqual(item.status(), .enabled)
        try item.setEnabled(false)
        XCTAssertEqual(item.status(), .disabled)
        XCTAssertEqual(item.calls, [true, false])
    }

    /// A refused registration must not leave the setting reading as enabled.
    func testRefusedRegistrationLeavesItDisabled() {
        let item = MockLoginItem()
        item.failure = RefusedRegistration()
        XCTAssertThrowsError(try item.setEnabled(true))
        XCTAssertEqual(item.status(), .disabled)
    }

    func testApprovalPendingIsDistinctFromEnabled() {
        let item = MockLoginItem()
        item.current = .requiresApproval
        XCTAssertNotEqual(item.status(), .enabled, "pending approval must not read as on")
    }

    /// The real SMAppService path: the test runner is not a registered bundle,
    /// so this must report a status rather than crash or claim to be enabled.
    func testLiveStatusIsReadableAndNotEnabled() {
        let status = SMAppServiceLoginItem().status()
        XCTAssertNotEqual(status, .enabled)
        XCTAssertTrue([.disabled, .requiresApproval, .unavailable].contains(status))
    }
}
