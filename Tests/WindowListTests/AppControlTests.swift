import AppKit
import CoreGraphics
import XCTest
@testable import WindowList

final class AppHiderStrategyTests: XCTestCase {
    func testRegularAppUsesAppHideFirst() throws {
        let desktop = FakeDesktop()
        let ax = MockAX(desktop: desktop)
        let strategy = try makeHider(desktop: desktop, apps: MockApps(desktop: desktop), ax: ax).hide(testApp())
        XCTAssertEqual(strategy, .appHide)
        XCTAssertTrue(ax.minimizeCalls.isEmpty, "must not fall through once app hide worked")
        XCTAssertTrue(desktop.visibleWindows.isEmpty)
    }

    /// The Nudge case: an accessory app, which AppKit's hide() cannot touch.
    func testAccessoryAppSkipsAppHide() throws {
        let desktop = FakeDesktop()
        let apps = MockApps(desktop: desktop, regular: [])
        let strategy = try makeHider(desktop: desktop, apps: apps, ax: MockAX(desktop: desktop))
            .hide(testApp(regular: false))
        XCTAssertEqual(strategy, .minimizeAll)
        XCTAssertTrue(apps.setCalls.isEmpty, "no point asking AppKit to hide an accessory app")
    }

    func testAppleScriptIsTriedBeforeMinimizing() throws {
        let desktop = FakeDesktop()
        let script = MockScript(desktop: desktop)
        script.supported = true
        let ax = MockAX(desktop: desktop)
        let strategy = try makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax, script: script)
            .hide(testApp(regular: false))
        XCTAssertEqual(strategy, .appleScript)
        XCTAssertTrue(ax.minimizeCalls.isEmpty)
    }

    /// AppKit reporting success while windows stay on screen is not a hide.
    func testSilentAppHideFailureFallsThrough() throws {
        let desktop = FakeDesktop()
        let apps = MockApps(desktop: desktop)
        apps.hideSilentlyFails = true
        let strategy = try makeHider(desktop: desktop, apps: apps, ax: MockAX(desktop: desktop)).hide(testApp())
        XCTAssertEqual(strategy, .minimizeAll)
        XCTAssertEqual(apps.setCalls.map(\.0), [true, false], "a failed app hide is rolled back first")
    }

    func testFallsThroughToOffScreenWhenMinimizeIsIgnored() throws {
        let desktop = FakeDesktop()
        let ax = MockAX(desktop: desktop)
        ax.minimizedSupported = false
        let strategy = try makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax)
            .hide(testApp(regular: false))
        XCTAssertEqual(strategy, .offScreenAll)
        XCTAssertEqual(ax.originCalls.map(\.1), [parkingOrigin])
    }

    func testAppThatResistsEverythingReportsEveryAttempt() {
        let desktop = FakeDesktop()
        let ax = MockAX(desktop: desktop)
        ax.minimizedSupported = false
        ax.moveSupported = false
        XCTAssertThrowsError(
            try makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax)
                .hide(testApp(regular: false))
        ) { error in
            XCTAssertEqual(
                error as? AppControlError,
                .allStrategiesFailed(app: "TextEdit", attempts: [.axHide, .appleScript, .minimizeAll, .offScreenAll])
            )
        }
        XCTAssertEqual(desktop.visibleWindows, [1], "a failed hide leaves the app as it found it")
    }

    func testFailedHideRollsBackEveryAttempt() {
        let desktop = FakeDesktop()
        let ax = MockAX(desktop: desktop)
        ax.minimizedSupported = false
        ax.moveSupported = false
        let script = MockScript(desktop: desktop)
        _ = try? makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax, script: script)
            .hide(testApp(regular: false))
        XCTAssertEqual(ax.minimizeCalls.map(\.1), [true, false], "minimize attempt undone")
        XCTAssertEqual(script.calls.map(\.1), [false, true], "System Events attempt undone")
    }
}

final class AXHideStrategyTests: XCTestCase {
    /// AXHidden leaves no Dock tile, so it must be tried before minimizing.
    func testAXHideIsPreferredOverMinimizing() throws {
        let desktop = FakeDesktop()
        let ax = MockAX(desktop: desktop)
        ax.appHideSupported = true
        let strategy = try makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax)
            .hide(testApp(regular: false))
        XCTAssertEqual(strategy, .axHide)
        XCTAssertEqual(ax.appHideCalls.map(\.1), [true])
        XCTAssertTrue(ax.minimizeCalls.filter { $0.1 }.isEmpty, "must not minimize once AXHidden worked")
    }

    /// Hiding an app does not clear a tile left by an earlier minimize, so any
    /// already-minimized window is restored before the app is hidden.
    func testAlreadyMinimizedWindowsAreRestoredBeforeHiding() throws {
        let desktop = FakeDesktop(visible: [2])
        let ax = MockAX(desktop: desktop)
        ax.appHideSupported = true
        let app = testApp(regular: false, windowIDs: [1, 2])
        let strategy = try makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax).hide(app)
        XCTAssertEqual(strategy, .axHide)
        XCTAssertEqual(ax.minimizeCalls.first?.0, 1, "the minimized window is un-minimized first")
        XCTAssertEqual(ax.minimizeCalls.first?.1, false)
    }

    func testFailedAXHideRestoresTheMinimizedWindow() {
        let desktop = FakeDesktop(visible: [2])
        let ax = MockAX(desktop: desktop)
        ax.minimizedSupported = false
        ax.moveSupported = false
        let app = testApp(regular: false, windowIDs: [1, 2])
        _ = try? makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax).hide(app)
        XCTAssertEqual(ax.appHideCalls.map(\.1), [true, false], "AXHidden is rolled back")
        XCTAssertTrue(ax.minimizeCalls.contains { $0 == (1, true) }, "window 1 is re-minimized")
    }

    func testShowUndoesAXHide() throws {
        let desktop = FakeDesktop()
        let ax = MockAX(desktop: desktop)
        ax.appHideSupported = true
        let hider = makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax)
        let app = testApp(regular: false)
        try hider.hide(app)
        try hider.show(app)
        XCTAssertEqual(ax.appHideCalls.map(\.1), [true, false])
        XCTAssertFalse(desktop.visibleWindows.isEmpty)
    }
}

final class AppHiderPermissionTests: XCTestCase {
    /// Without Accessibility, strategies 3 and 4 cannot run at all — saying the
    /// app "resisted every method" would blame it for a local permission gap.
    func testAgentAppWithoutAccessibilityReportsThePermission() {
        let desktop = FakeDesktop()
        let ax = MockAX(desktop: desktop)
        ax.trusted = false
        XCTAssertThrowsError(
            try makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax)
                .hide(testApp(regular: false))
        ) { error in
            XCTAssertEqual(error as? AppControlError, .accessibilityRequired(app: "TextEdit"))
        }
    }

    func testUntrustedAccessibilityStillAllowsRegularAppHide() throws {
        let desktop = FakeDesktop()
        let ax = MockAX(desktop: desktop)
        ax.trusted = false
        let strategy = try makeHider(desktop: desktop, apps: MockApps(desktop: desktop), ax: ax).hide(testApp())
        XCTAssertEqual(strategy, .appHide)
    }

    /// Screen Recording is deliberately not requested; titles come from AX.
    func testDiagnosticsDoNotMentionScreenRecording() {
        XCTAssertFalse(Diagnostics.report().lowercased().contains("screen recording"))
    }

    /// Guards the diagnostics the permission story is debugged with.
    func testDiagnosticsReportNamesEveryPermission() {
        let report = Diagnostics.report()
        for field in ["accessibility:", "bundle id:", "open at login:", "apps with windows:", "apps detected:"] {
            XCTAssertTrue(report.contains(field), "diagnostics missing \(field)")
        }
    }
}

final class AppHiderMultiWindowTests: XCTestCase {
    func testMinimizeHidesEveryWindowOfTheApp() throws {
        let desktop = FakeDesktop(visible: [1, 2, 3])
        let ax = MockAX(desktop: desktop)
        let app = testApp(regular: false, windowIDs: [1, 2, 3])
        let strategy = try makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax).hide(app)
        XCTAssertEqual(strategy, .minimizeAll)
        XCTAssertEqual(ax.minimizeCalls.map(\.0), [1, 2, 3])
        XCTAssertTrue(desktop.visibleWindows.isEmpty)
    }

    /// One stubborn window must not let the app count as hidden.
    func testOneRemainingVisibleWindowMeansNotHidden() throws {
        let desktop = FakeDesktop(visible: [1, 2])
        let ax = StubbornAX(desktop: desktop, stubbornID: 2)
        let app = testApp(regular: false, windowIDs: [1, 2])
        let hider = AppHider(
            apps: MockApps(desktop: desktop, regular: []),
            ax: ax,
            script: MockScript(desktop: desktop),
            processes: MockProcesses(desktop: desktop),
            probe: MockProbe(desktop: desktop),
            selfPID: 999,
            settleTimeout: 0.05
        )
        XCTAssertThrowsError(try hider.hide(app))
    }

    func testShowRestoresEveryParkedWindowToItsOwnOrigin() throws {
        let desktop = FakeDesktop(visible: [1, 2])
        let ax = MockAX(desktop: desktop)
        ax.minimizedSupported = false
        ax.origins = [1: CGPoint(x: 100, y: 100), 2: CGPoint(x: 369, y: 184)]
        let app = testApp(regular: false, windowIDs: [1, 2])
        let hider = makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax)
        try hider.hide(app)
        try hider.show(app)
        XCTAssertEqual(ax.origins[1], CGPoint(x: 100, y: 100))
        XCTAssertEqual(ax.origins[2], CGPoint(x: 369, y: 184))
    }
}

/// An app where one window refuses to minimize or move.
private final class StubbornAX: AXWindowController {
    let desktop: FakeDesktop
    let stubbornID: CGWindowID

    init(desktop: FakeDesktop, stubbornID: CGWindowID) {
        self.desktop = desktop
        self.stubbornID = stubbornID
    }

    func isTrusted() -> Bool { true }
    func setAppHidden(_ hidden: Bool, pid: pid_t) throws {}
    func windowTitles(pid: pid_t) -> [String] { [] }

    func setMinimized(_ value: Bool, for window: WindowInfo) throws {
        guard window.id != stubbornID else { return }
        if value { desktop.visibleWindows.remove(window.id) } else { desktop.visibleWindows.insert(window.id) }
    }

    func origin(of window: WindowInfo) throws -> CGPoint { CGPoint(x: 10, y: 20) }
    func setOrigin(_ origin: CGPoint, for window: WindowInfo) throws {}
}

final class AppHiderFreezeTests: XCTestCase {
    func testFreezeHappensOnlyAfterTheHideIsVerified() throws {
        let desktop = FakeDesktop()
        let processes = MockProcesses(desktop: desktop)
        let hider = makeHider(desktop: desktop, apps: MockApps(desktop: desktop), ax: MockAX(desktop: desktop), processes: processes)
        try hider.hide(testApp(), freeze: true)
        XCTAssertEqual(processes.calls, ["freeze(100)"])
        XCTAssertTrue(desktop.frozenPIDs.contains(100))
    }

    func testNoFreezeWhenNotRequested() throws {
        let desktop = FakeDesktop()
        let processes = MockProcesses(desktop: desktop)
        try makeHider(desktop: desktop, apps: MockApps(desktop: desktop), ax: MockAX(desktop: desktop), processes: processes)
            .hide(testApp(), freeze: false)
        XCTAssertTrue(processes.calls.isEmpty)
    }

    func testFailedHideNeverFreezes() {
        let desktop = FakeDesktop()
        let ax = MockAX(desktop: desktop)
        ax.minimizedSupported = false
        ax.moveSupported = false
        let processes = MockProcesses(desktop: desktop)
        _ = try? makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax, processes: processes)
            .hide(testApp(regular: false), freeze: true)
        XCTAssertTrue(processes.calls.isEmpty, "freezing an app that is still visible would strand it")
    }

    /// A stopped process cannot act on a restore request, so it must be thawed first.
    func testShowResumesBeforeRestoring() throws {
        let desktop = FakeDesktop()
        let processes = MockProcesses(desktop: desktop)
        let apps = MockApps(desktop: desktop)
        let hider = makeHider(desktop: desktop, apps: apps, ax: MockAX(desktop: desktop), processes: processes)
        try hider.hide(testApp(), freeze: true)
        try hider.show(testApp())
        XCTAssertEqual(processes.calls, ["freeze(100)", "resume(100)"])
        XCTAssertFalse(desktop.frozenPIDs.contains(100))
        XCTAssertFalse(desktop.visibleWindows.isEmpty)
    }

    func testHidingAnAlreadyFrozenAppThawsItFirst() throws {
        let desktop = FakeDesktop()
        desktop.frozenPIDs.insert(100)
        let processes = MockProcesses(desktop: desktop)
        try makeHider(desktop: desktop, apps: MockApps(desktop: desktop), ax: MockAX(desktop: desktop), processes: processes)
            .hide(testApp())
        XCTAssertEqual(processes.calls.first, "resume(100)", "a stopped app can't process a hide")
    }

    /// The hide still stands even if the freeze fails; the error must say so.
    func testFreezeFailureIsReportedButHideStands() {
        let desktop = FakeDesktop()
        let processes = MockProcesses(desktop: desktop)
        processes.freezeFails = true
        let hider = makeHider(desktop: desktop, apps: MockApps(desktop: desktop), ax: MockAX(desktop: desktop), processes: processes)
        XCTAssertThrowsError(try hider.hide(testApp(), freeze: true))
        XCTAssertTrue(desktop.visibleWindows.isEmpty, "app is still hidden")
        XCTAssertFalse(desktop.frozenPIDs.contains(100))
        XCTAssertEqual(hider.state(of: testApp()), .hidden(.appHide), "the hide is still recorded")
    }
}

final class AppHiderStateTests: XCTestCase {
    func testStateTracksTheWindowServer() throws {
        let desktop = FakeDesktop()
        let hider = makeHider(desktop: desktop, apps: MockApps(desktop: desktop), ax: MockAX(desktop: desktop))
        XCTAssertEqual(hider.state(of: testApp()), .visible)
        try hider.hide(testApp())
        XCTAssertEqual(hider.state(of: testApp()), .hidden(.appHide))
    }

    func testStateForAppHiddenBySomethingElse() {
        let desktop = FakeDesktop(visible: [])
        desktop.appHidden = true
        let hider = makeHider(desktop: desktop, apps: MockApps(desktop: desktop), ax: MockAX(desktop: desktop))
        XCTAssertEqual(hider.state(of: testApp()), .hidden(nil))
    }

    func testShowRecoversAnAppThisToolDidNotHide() throws {
        let desktop = FakeDesktop(visible: [])
        desktop.appHidden = true
        let apps = MockApps(desktop: desktop)
        let hider = makeHider(desktop: desktop, apps: apps, ax: MockAX(desktop: desktop))
        try hider.show(testApp())
        XCTAssertFalse(desktop.visibleWindows.isEmpty)
    }

    func testShowReportsFailureWhenTheAppStaysGone() {
        let desktop = FakeDesktop(visible: [])
        let ax = MockAX(desktop: desktop)
        ax.minimizedSupported = false
        let hider = makeHider(desktop: desktop, apps: MockApps(desktop: desktop, regular: []), ax: ax)
        XCTAssertThrowsError(try hider.show(testApp(regular: false))) {
            XCTAssertEqual($0 as? AppControlError, .restoreFailed(app: "TextEdit"))
        }
    }

    func testStateUnknownForDeadProcess() {
        let desktop = FakeDesktop()
        let hider = makeHider(desktop: desktop, apps: MockApps(desktop: desktop, knownPIDs: []), ax: MockAX(desktop: desktop))
        XCTAssertEqual(hider.state(of: testApp(pid: 7)), .unknown)
    }

    func testToggleHidesThenShows() throws {
        let desktop = FakeDesktop()
        let hider = makeHider(desktop: desktop, apps: MockApps(desktop: desktop), ax: MockAX(desktop: desktop))
        try hider.toggle(testApp())
        XCTAssertTrue(desktop.visibleWindows.isEmpty)
        try hider.toggle(testApp())
        XCTAssertFalse(desktop.visibleWindows.isEmpty)
    }

    func testRefusesToHideItself() {
        let desktop = FakeDesktop()
        let apps = MockApps(desktop: desktop, knownPIDs: [42], regular: [42])
        let hider = makeHider(desktop: desktop, apps: apps, ax: MockAX(desktop: desktop), selfPID: 42)
        XCTAssertThrowsError(try hider.hide(testApp(pid: 42))) {
            XCTAssertEqual($0 as? AppControlError, .cannotHideSelf)
        }
        XCTAssertTrue(apps.setCalls.isEmpty)
    }

    /// Windowless apps are listable in "all apps" mode, so they must be
    /// hideable too — with AppKit's own hidden flag as the only evidence.
    func testWindowlessAppIsHiddenAndVerifiedViaAppKit() throws {
        let desktop = FakeDesktop()
        let app = AppInfo(pid: 100, name: "TextEdit", bundleID: nil, isRegular: true, windows: [])
        let hider = makeHider(desktop: desktop, apps: MockApps(desktop: desktop), ax: MockAX(desktop: desktop))
        XCTAssertEqual(hider.state(of: app), .visible)
        XCTAssertEqual(try hider.hide(app), .appHide)
        XCTAssertTrue(desktop.appHidden)
        XCTAssertEqual(hider.state(of: app), .hidden(.appHide))
        try hider.show(app)
        XCTAssertEqual(hider.state(of: app), .visible)
    }

    func testWindowlessAppThatWillNotHideReportsFailure() {
        let desktop = FakeDesktop()
        let apps = MockApps(desktop: desktop, regular: [])
        let app = AppInfo(pid: 100, name: "Agent", bundleID: nil, isRegular: false, windows: [])
        let hider = makeHider(desktop: desktop, apps: apps, ax: MockAX(desktop: desktop))
        XCTAssertThrowsError(try hider.hide(app))
    }
}

final class LiveProcessControlTests: XCTestCase {
    /// Guards the sysctl path: this process is definitely not stopped.
    func testThisProcessIsNotReportedFrozen() {
        let pid = ProcessInfo.processInfo.processIdentifier
        XCTAssertFalse(SignalProcessController().isFrozen(pid: pid))
    }

    func testUnknownPIDIsNotReportedFrozen() {
        XCTAssertFalse(SignalProcessController().isFrozen(pid: 999_999))
    }

    /// Freeze/resume against a real child process, end to end.
    func testFreezeAndResumeARealProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }

        let controller = SignalProcessController()
        let pid = process.processIdentifier
        XCTAssertTrue(pollUntil(timeout: 2) { !controller.isFrozen(pid: pid) })

        try controller.freeze(pid: pid)
        XCTAssertTrue(pollUntil(timeout: 2) { controller.isFrozen(pid: pid) }, "SIGSTOP did not take")

        try controller.resume(pid: pid)
        XCTAssertTrue(pollUntil(timeout: 2) { !controller.isFrozen(pid: pid) }, "SIGCONT did not take")
    }

    func testSignallingAForbiddenProcessThrows() {
        // pid 1 (launchd) belongs to root; we must not claim success.
        XCTAssertThrowsError(try SignalProcessController().freeze(pid: 1))
    }
}
