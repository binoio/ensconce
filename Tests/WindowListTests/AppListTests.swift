import CoreGraphics
import XCTest
@testable import WindowList

private struct StubSource: WindowSource {
    let dictionaries: [[String: Any]]
    func windowDictionaries() -> [[String: Any]] { dictionaries }
}

private func dict(id: CGWindowID, pid: pid_t, owner: String, title: String) -> [String: Any] {
    [
        kCGWindowNumber as String: id,
        kCGWindowOwnerName as String: owner,
        kCGWindowOwnerPID as String: pid,
        kCGWindowLayer as String: 0,
        kCGWindowIsOnscreen as String: true,
        kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 800, height: 600)
            .dictionaryRepresentation as! [String: Any],
    ]
}

private struct StubProvider: RunningAppsProvider {
    let apps: [RunningAppSnapshot]
    func allApps() -> [RunningAppSnapshot] { apps }
}

final class AppListerTests: XCTestCase {
    private func lister(
        _ dicts: [[String: Any]],
        desktop: FakeDesktop,
        known: Set<pid_t>,
        regular: Set<pid_t>? = nil,
        executables: [pid_t: String] = [:],
        provider: [RunningAppSnapshot] = []
    ) -> AppLister {
        let apps = MockApps(desktop: desktop, knownPIDs: known, regular: regular ?? known)
        apps.executables = executables
        return AppLister(
            windows: WindowLister(source: StubSource(dictionaries: dicts)),
            apps: apps,
            provider: StubProvider(apps: provider)
        )
    }

    /// The default list is only apps that actually have windows.
    func testWindowlessAppsAreExcludedByDefault() {
        let apps = lister(
            [dict(id: 1, pid: 100, owner: "Safari", title: "One")],
            desktop: FakeDesktop(),
            known: [100],
            provider: [
                RunningAppSnapshot(pid: 100, name: "Safari", bundleID: "com.apple.Safari", isRegular: true),
                RunningAppSnapshot(pid: 300, name: "Dropbox", bundleID: "com.dropbox", isRegular: false),
            ]
        ).listApps()
        XCTAssertEqual(apps.map(\.pid), [100])
    }

    func testIncludeWindowlessAddsEveryOtherRunningApp() {
        let apps = lister(
            [dict(id: 1, pid: 100, owner: "Safari", title: "One")],
            desktop: FakeDesktop(),
            known: [100],
            provider: [
                RunningAppSnapshot(pid: 100, name: "Safari", bundleID: "com.apple.Safari", isRegular: true),
                RunningAppSnapshot(pid: 300, name: "Dropbox", bundleID: "com.dropbox", isRegular: false),
            ]
        ).listApps(includeWindowless: true)
        XCTAssertEqual(apps.map(\.pid).sorted(), [100, 300])
        XCTAssertTrue(apps.first { $0.pid == 300 }?.windows.isEmpty ?? false)
    }

    /// An app appearing in both sources must not be listed twice.
    func testAppWithWindowsIsNotDuplicatedByTheProvider() {
        let apps = lister(
            [dict(id: 1, pid: 100, owner: "Safari", title: "One")],
            desktop: FakeDesktop(),
            known: [100],
            provider: [RunningAppSnapshot(pid: 100, name: "Safari", bundleID: nil, isRegular: true)]
        ).listApps(includeWindowless: true)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].windows.count, 1, "the windowed entry wins")
    }

    // MARK: System processes

    func testSystemProcessesAreOSHelpersThatAreNotRegularApps() {
        let system = [
            "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
            "/System/Library/Frameworks/AppKit.framework/Versions/C/XPCServices/DocumentPopoverViewService.xpc/Contents/MacOS/DocumentPopoverViewService",
            "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
            "/System/Library/Input Methods/CharacterPalette.app/Contents/MacOS/CharacterPalette",
            "/System/Applications/Siri AI.app/Contents/MacOS/Siri AI",
            "/usr/libexec/somehelper",
        ]
        for path in system {
            XCTAssertTrue(AppInfo.isSystemProcess(executablePath: path, isRegular: false), path)
        }

        let user = [
            "/Users/me/Applications/Kona.app/Contents/MacOS/Kona",
            "/Applications/Dropbox.app/Contents/MacOS/Dropbox",
            "/System/Volumes/Data/Users/me/Applications/Edith.app/Contents/MacOS/Edith",
            "/opt/homebrew/bin/tool",
        ]
        for path in user {
            XCTAssertFalse(AppInfo.isSystemProcess(executablePath: path, isRegular: false), path)
        }
    }

    /// Finder lives in CoreServices and Calendar in /System/Applications, but
    /// both are regular apps the user wants to hide — never system noise.
    func testRegularAppsAreNeverSystemProcesses() {
        XCTAssertFalse(AppInfo.isSystemProcess(
            executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", isRegular: true))
        XCTAssertFalse(AppInfo.isSystemProcess(
            executablePath: "/System/Applications/Calendar.app/Contents/MacOS/Calendar", isRegular: true))
    }

    func testUnknownExecutableIsNotSystem() {
        XCTAssertFalse(AppInfo.isSystemProcess(executablePath: nil, isRegular: false))
    }

    func testSystemProcessesAreExcludedByDefault() {
        let apps = lister(
            [
                dict(id: 1, pid: 100, owner: "Safari", title: "One"),
                dict(id: 2, pid: 200, owner: "loginwindow", title: ""),
                dict(id: 3, pid: 300, owner: "Finder", title: "Desktop"),
            ],
            desktop: FakeDesktop(),
            known: [100, 200, 300],
            regular: [100, 300],
            executables: [
                200: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
                300: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            ]
        ).listApps()
        XCTAssertEqual(apps.map(\.pid).sorted(), [100, 300])
        XCTAssertTrue(apps.allSatisfy { !$0.isSystem })
    }

    func testIncludeSystemKeepsThemAndFlagsThem() {
        let apps = lister(
            [
                dict(id: 1, pid: 100, owner: "Safari", title: "One"),
                dict(id: 2, pid: 200, owner: "loginwindow", title: ""),
            ],
            desktop: FakeDesktop(),
            known: [100, 200],
            regular: [100],
            executables: [200: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"]
        ).listApps(includeSystem: true)
        XCTAssertEqual(apps.map(\.pid).sorted(), [100, 200])
        XCTAssertEqual(apps.first { $0.pid == 200 }?.isSystem, true)
        XCTAssertEqual(apps.first { $0.pid == 100 }?.isSystem, false)
    }

    /// The filter applies to windowless apps from the provider too.
    func testSystemFilterAppliesToWindowlessApps() {
        let provider = [
            RunningAppSnapshot(pid: 300, name: "Dropbox", bundleID: "com.dropbox", isRegular: false,
                               executablePath: "/Applications/Dropbox.app/Contents/MacOS/Dropbox"),
            RunningAppSnapshot(pid: 400, name: "UserNotificationCenter", bundleID: "com.apple.UNC", isRegular: false,
                               executablePath: "/System/Library/CoreServices/UserNotificationCenter.app/Contents/MacOS/UserNotificationCenter"),
        ]
        let filtered = lister([], desktop: FakeDesktop(), known: [], provider: provider)
            .listApps(includeWindowless: true)
        XCTAssertEqual(filtered.map(\.pid), [300])

        let all = lister([], desktop: FakeDesktop(), known: [], provider: provider)
            .listApps(includeWindowless: true, includeSystem: true)
        XCTAssertEqual(all.map(\.pid).sorted(), [300, 400])
    }

    func testGroupsWindowsByProcess() {
        let apps = lister([
            dict(id: 1, pid: 100, owner: "Safari", title: "One"),
            dict(id: 2, pid: 100, owner: "Safari", title: "Two"),
            dict(id: 3, pid: 200, owner: "Mail", title: "Inbox"),
        ], desktop: FakeDesktop(), known: [100, 200]).listApps()

        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps.map(\.pid).sorted(), [100, 200])
        XCTAssertEqual(apps.first { $0.pid == 100 }?.windows.count, 2)
    }

    /// Two processes of the same app stay separate — they hide independently.
    func testSameNamedProcessesAreNotMerged() {
        let apps = lister([
            dict(id: 1, pid: 100, owner: "Safari", title: "One"),
            dict(id: 2, pid: 101, owner: "Safari", title: "Two"),
        ], desktop: FakeDesktop(), known: [100, 101]).listApps()
        XCTAssertEqual(apps.count, 2)
    }

    func testFallsBackToTheWindowOwnerWhenAppKitKnowsNothing() {
        let apps = lister([dict(id: 1, pid: 500, owner: "Nudge", title: "Nudge")],
                          desktop: FakeDesktop(), known: []).listApps()
        XCTAssertEqual(apps.first?.name, "Nudge")
        XCTAssertNil(apps.first?.bundleID)
        XCTAssertFalse(apps.first?.isRegular ?? true)
    }

    func testSortedByNameCaseInsensitively() {
        let apps = lister([
            dict(id: 1, pid: 100, owner: "zed", title: "z"),
            dict(id: 2, pid: 200, owner: "Ableton", title: "a"),
        ], desktop: FakeDesktop(), known: []).listApps()
        XCTAssertEqual(apps.map(\.name), ["Ableton", "zed"])
    }

    func testNoWindowsMeansNoApps() {
        XCTAssertTrue(lister([], desktop: FakeDesktop(), known: []).listApps().isEmpty)
    }

    func testWindowTitlesLabelUntitledWindows() {
        let app = AppInfo(pid: 1, name: "X", bundleID: nil, isRegular: true, windows: [
            WindowInfo(id: 1, title: "", owner: "X", ownerPID: 1, bounds: .zero, layer: 0),
        ])
        XCTAssertEqual(app.windowTitles, ["(untitled)"])
    }

    /// Guards against a stub-only suite: the real desktop must produce apps.
    func testLiveListerFindsRunningApps() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "No window server in CI")
        let windowed = AppLister().listApps()
        XCTAssertFalse(windowed.isEmpty)
        XCTAssertTrue(windowed.allSatisfy { !$0.windows.isEmpty }, "every default-listed app must own a window")

        let all = AppLister().listApps(includeWindowless: true)
        XCTAssertGreaterThan(all.count, windowed.count, "showing all apps must add the windowless ones")
        XCTAssertEqual(Set(all.map(\.pid)).count, all.count, "no duplicate processes")
        XCTAssertTrue(all.allSatisfy { !$0.isSystem }, "system processes are filtered by default")

        let withSystem = AppLister().listApps(includeWindowless: true, includeSystem: true)
        XCTAssertGreaterThan(withSystem.count, all.count, "a live Mac always has OS helper processes running")
        XCTAssertTrue(withSystem.contains { $0.isSystem })
    }
}
