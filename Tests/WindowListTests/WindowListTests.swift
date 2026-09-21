import CoreGraphics
import XCTest
@testable import WindowList

/// Serves canned window-server dictionaries so tests never depend on the live desktop.
private struct StubSource: WindowSource {
    let dictionaries: [[String: Any]]
    func windowDictionaries() -> [[String: Any]] { dictionaries }
}

private func windowDict(
    id: CGWindowID,
    owner: String,
    pid: pid_t = 100,
    title: String? = nil,
    layer: Int = 0,
    bounds: CGRect? = CGRect(x: 0, y: 0, width: 800, height: 600),
    onScreen: Bool? = true
) -> [String: Any] {
    var dict: [String: Any] = [
        kCGWindowNumber as String: id,
        kCGWindowOwnerName as String: owner,
        kCGWindowOwnerPID as String: pid,
        kCGWindowLayer as String: layer,
    ]
    if let onScreen { dict[kCGWindowIsOnscreen as String] = onScreen }
    if let title { dict[kCGWindowName as String] = title }
    if let bounds { dict[kCGWindowBounds as String] = bounds.dictionaryRepresentation as! [String: Any] }
    return dict
}

final class WindowListTests: XCTestCase {
    func testParsesFullDictionary() throws {
        let info = try XCTUnwrap(WindowInfo(dictionary: windowDict(id: 7, owner: "Safari", pid: 42, title: "Home")))
        XCTAssertEqual(info.id, 7)
        XCTAssertEqual(info.owner, "Safari")
        XCTAssertEqual(info.ownerPID, 42)
        XCTAssertEqual(info.title, "Home")
        XCTAssertEqual(info.bounds, CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    func testMissingTitleBecomesEmptyStringNotFailure() throws {
        let info = try XCTUnwrap(WindowInfo(dictionary: windowDict(id: 1, owner: "Finder")))
        XCTAssertEqual(info.title, "")
    }

    func testMissingRequiredKeysRejected() {
        XCTAssertNil(WindowInfo(dictionary: [:]))
        XCTAssertNil(WindowInfo(dictionary: [kCGWindowNumber as String: CGWindowID(1)]))
        XCTAssertNil(WindowInfo(dictionary: [kCGWindowOwnerName as String: "Safari"]))
    }

    func testMissingBoundsFallsBackToZero() throws {
        let info = try XCTUnwrap(WindowInfo(dictionary: windowDict(id: 2, owner: "Mail", bounds: nil)))
        XCTAssertEqual(info.bounds, .zero)
    }

    func testListerFiltersNonZeroLayersAndSorts() {
        let source = StubSource(dictionaries: [
            windowDict(id: 3, owner: "Zed", title: "b"),
            windowDict(id: 4, owner: "aterm", title: "a"),
            windowDict(id: 5, owner: "Dock", title: "menubar", layer: 25),
            ["garbage": true],
        ])
        let windows = WindowLister(source: source).listWindows()
        XCTAssertEqual(windows.map(\.id), [4, 3], "layer-25 and malformed entries must be dropped, sort is case-insensitive by owner")
    }

    func testEmptySourceYieldsEmptyList() {
        XCTAssertTrue(WindowLister(source: StubSource(dictionaries: [])).listWindows().isEmpty)
    }

    /// Guards against a stub-only suite: the real source must return something on a live Mac.
    func testLiveSourceReturnsWindowsWhenAvailable() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "No window server in CI")
        XCTAssertFalse(CoreGraphicsWindowSource().windowDictionaries().isEmpty, "window server returned no windows at all")
    }

    func testOnScreenFlagParsing() throws {
        let visible = try XCTUnwrap(WindowInfo(dictionary: windowDict(id: 1, owner: "Safari", onScreen: true)))
        XCTAssertTrue(visible.isOnScreen)
        let minimized = try XCTUnwrap(WindowInfo(dictionary: windowDict(id: 2, owner: "Safari", onScreen: false)))
        XCTAssertFalse(minimized.isOnScreen)
        // CoreGraphics omits the key entirely for off-screen windows.
        let absent = try XCTUnwrap(WindowInfo(dictionary: windowDict(id: 3, owner: "Safari", onScreen: nil)))
        XCTAssertFalse(absent.isOnScreen)
    }

    func testListerKeepsMinimizedWindowsSoTheyCanBeRestored() {
        let source = StubSource(dictionaries: [windowDict(id: 9, owner: "Safari", title: "Home", onScreen: false)])
        let windows = WindowLister(source: source).listWindows()
        XCTAssertEqual(windows.map(\.id), [9])
        XCTAssertFalse(windows[0].isOnScreen)
    }

    func testListerDropsZeroSizedWindows() {
        let source = StubSource(dictionaries: [
            windowDict(id: 10, owner: "Safari", bounds: CGRect(x: 0, y: 0, width: 0, height: 0)),
            windowDict(id: 11, owner: "Safari", bounds: nil),
            windowDict(id: 12, owner: "Safari"),
        ])
        XCTAssertEqual(WindowLister(source: source).listWindows().map(\.id), [12])
    }
}
