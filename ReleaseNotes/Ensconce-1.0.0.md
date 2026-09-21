# Ensconce 1.0.0

Initial release of **Ensconce** — a macOS app that lists every running app with open windows and hides or shows them wholesale, including the ones that refuse ⌘H.

### Features
- **One row per process**: every app with open windows, with a Hide/Show button. Two processes of the same app stay separate because they hide independently.
- **Five hide strategies, each verified against the window server**: AppKit hide, Accessibility `AXHidden`, System Events, per-window minimize, and parking windows off-screen. Failed attempts roll back before the next is tried.
- **Freeze when hidden**: optionally `SIGSTOP` a hidden app so it cannot re-show itself; Show resumes it.
- **Get Info** (⌘I): pid, bundle ID, executable, kind, hide state, and every window with its bounds, for the highlighted row.
- **View toggles**: show all detected apps (including windowless ones), show app details, and show system processes — macOS helpers such as loginwindow and XPC view services are filtered out by default.
- **Settings**: open at login, freeze on hide, an Accessibility permission panel, and Sparkle update preferences.
- **Sparkle 2 updates**: automatic software update checks.
- **Apple Developer notarized**: signed and notarized with Hardened Runtime for macOS 14 and later.
