#!/bin/zsh
# Clears and re-requests Ensconce's TCC grants.
#
# Needed after most rebuilds: an ad-hoc signature's identity IS its code hash,
# which changes on every build, so an existing grant goes stale while System
# Settings still shows the checkbox ticked. Resetting avoids the confusing
# "permission looks granted but AXIsProcessTrusted() is false" state.
# Sign with a stable identity (see build.sh, CODESIGN_IDENTITY) to avoid this.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="io.binoio.Ensconce"

echo "Resetting TCC entries for $BUNDLE_ID…"
tccutil reset Accessibility "$BUNDLE_ID" || true
tccutil reset ScreenCapture "$BUNDLE_ID" || true

echo "Quitting any running copy…"
pkill -f 'Ensconce.app/Contents/MacOS/Ensconce' || true

open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

cat <<'INSTRUCTIONS'

In System Settings → Privacy & Security:
  1. Accessibility   → + → add build/Ensconce.app, and switch it ON
  2. Screen Recording → same app (titles only; hiding works without it)
  3. Relaunch:  ./Scripts/run.sh

Verify it took — this reads the app's own report, not the checkbox:
  tail -8 ~/Library/Logs/Ensconce.log
INSTRUCTIONS
