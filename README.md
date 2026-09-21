# Ensconce

A macOS SwiftUI app that lists every running app with open windows, and hides or shows them wholesale — including the stubborn ones that ignore ⌘H.

Product page: [bino.io/ensconce](https://bino.io/ensconce/) · Releases: [github.com/binoio/ensconce/releases](https://github.com/binoio/ensconce/releases)

## Use

```zsh
./Scripts/run.sh                  # build (debug) + launch
./Scripts/build.sh                # release build -> build/Ensconce.app (Sparkle embedded)
./Scripts/test.sh                 # unit tests
swift Scripts/generate-icon.swift # regenerate Resources/AppIcon.icns and docs/icon.png
./Scripts/release.sh              # sign, notarize, publish a GitHub release + appcast
```

## Notes

- The list shows app names only, one row per **process**. Two processes of the
  same app stay separate rows, because they hide independently.
- **View → Show All Detected Apps** (⇧⌘L) adds every running app AppKit knows
  about, including those with no windows. Those are hidden and verified through
  AppKit's own hidden flag, since there is no window to watch.
- **View → Show App Details** (⇧⌘D) adds pid, window count, and app/agent.
- Click a row to highlight it; **File → Get Info** (⌘I, or the row's context
  menu) opens a window with its pid, bundle ID, executable, kind, hide state,
  Accessibility window titles, and every window with its bounds. It reads the
  process fresh, including ones the list is currently filtering.
- **View → Show System Processes** (⇧⌘S, default off) adds macOS's own helper
  processes — loginwindow, UserNotificationCenter, XPC view services, WebKit
  content processes — tagged **system**. A process counts as system when its
  executable lives under `/System/` or `/usr/` *and* it is not a regular app,
  so Finder, Calendar and the rest of `/System/Applications` are always listed.
- Window enumeration uses `CGWindowListCopyWindowInfo` with
  `.optionAll | .excludeDesktopElements`; `.optionAll` keeps minimized and
  hidden windows listed so their Show button stays reachable.

## Hiding

Hide tries four strategies in order and **verifies each against the window
server** — an app counts as hidden only when none of its windows is ordered in
and overlapping a display:

1. `NSRunningApplication.hide()` — the real ⌘H. Skipped for accessory/agent
   apps (activation policy != `.regular`), which AppKit always refuses.
2. `AXHidden` on the **application** element — the Accessibility route to the
   same hide. This reaches accessory apps AppKit refuses, and unlike minimizing
   it leaves **no Dock tile**. Windows minimized earlier are restored first,
   because hiding an app does not clear a tile that already exists.
3. System Events `set visible to false` — another path that reaches some apps
   AppKit will not. Needs Automation permission.
4. `AXMinimized` on every window. Works widely, but leaves a Dock tile.
5. Park every window beyond all displays, remembering each frame.

Failed attempts are rolled back before the next is tried; if all four fail the
row names every method attempted.

Window titles are read through Accessibility, not CoreGraphics, so **Screen
Recording is never requested**.

Verification cannot use these APIs' own results: some apps report success on a
position change they ignore, and others expose `AXMinimized` as settable but
return `kAXErrorAttributeUnsupported` when it is read, though setting it works.

A row shows an **in Dock** tag when one of its windows still has a minimized
tile, so a partial hide is visible rather than silent.

### Freeze when hidden

With the toolbar toggle on, a verified hide is followed by `SIGSTOP`, so an app
that re-shows itself cannot. Show sends `SIGCONT` first — a stopped process
cannot act on a restore request. Frozen apps do no background work (sync,
timers, network) until resumed, and the state is read back from the kernel
(`sysctl` `p_stat == SSTOP`) rather than assumed.

Deliberately not implemented: terminating apps, `launchctl bootout/disable` of
LaunchAgents, and patching `LSUIElement` into an app bundle's Info.plist. All
three work, but they are destructive, need root, and/or break code signatures.

## Settings

⌘, opens Settings:

- **Automatically open at login** (default off) — `SMAppService.mainApp`.
  Registration can be refused for an unsigned or ad-hoc build, or need approval
  in System Settings → General → Login Items; the switch reports what the
  system actually holds rather than what was asked for.
- **Freeze apps when hiding them** (default off) — see above.
- **Permissions** — shows whether Accessibility is granted and offers
  **Grant…** (the system prompt) or **Open System Settings…**; re-checked
  whenever Ensconce comes back to the front.
- **Updates** — Sparkle: automatic check/download toggles, last-checked time,
  and **Check for Updates…** (also in the Ensconce menu).

## Permissions

- **Accessibility** — strategies 2, 4 and 5, and reading Dock tiles. Regular
  apps can be hidden without it; agent apps cannot be hidden at all without it.
  Granted from Settings → Permissions.
- **Automation (System Events)** — strategy 3, prompted on first use.
- Grants are tied to the code signature. Ad-hoc signing changes identity on
  every rebuild, which silently invalidates them while System Settings still
  shows the checkbox ticked — run `./Scripts/grant-permissions.sh`, or set
  `CODESIGN_IDENTITY` to a stable identity. `~/Library/Logs/Ensconce.log`
  records what the app itself can see on each launch.
- Hiding Ensconce itself is blocked; its own row's button is disabled.

## Releasing

`Scripts/release.sh` builds a release bundle, signs it inside-out with the
Developer ID identity, notarizes it, generates the Sparkle appcast with the
EdDSA key in the login Keychain, publishes a GitHub release, and commits
`docs/appcast.xml`, which GitHub Pages serves at
`https://binoio.github.io/ensconce/appcast.xml` (the `SUFeedURL` in
`Resources/Info.plist`). Bump `VERSION` and add
`ReleaseNotes/Ensconce-<version>.{md,html}` first.

The icon is generated, not drawn: `Scripts/generate-icon.swift` renders an app
window slipping into a pocket at every icon size and writes both the `.icns`
and the product page's `icon.png`.

## Testing

- `./Scripts/test.sh` runs the XCTest suite. It must run on macOS — the library
  links CoreGraphics, so a Linux Docker container cannot build it. Set `CI=1`
  to skip the one test that touches the live window server.
- If the test bundle fails to load with "library load disallowed by system
  policy", the checkout carries a quarantine attribute (AirDrop, browser
  download) that the build products inherit: `xattr -dr com.apple.quarantine .`
