#!/bin/zsh
# Builds Ensconce and packages it as build/Ensconce.app, with Sparkle embedded.
#   ./Scripts/build.sh            # release
#   ./Scripts/build.sh debug
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Ensconce"
APP="build/Ensconce.app"
CONTENTS="$APP/Contents"
VERSION="$(tr -d '[:space:]' < VERSION)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BIN" "$CONTENTS/MacOS/Ensconce"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$CONTENTS/Info.plist"

# The executable links Sparkle via @rpath/../Frameworks (see Package.swift).
SPARKLE="$(find .build -type d -name Sparkle.framework -path '*artifacts*' -not -path '*dSYM*' | head -1)"
[[ -n "$SPARKLE" ]] || { echo "error: Sparkle.framework not found under .build" >&2; exit 1; }
# ditto keeps the framework's Versions symlink structure; cp -R would flatten it.
ditto "$SPARKLE" "$CONTENTS/Frameworks/Sparkle.framework"

# A stable signing identity keeps Accessibility grants across rebuilds. Without
# one, ad-hoc signing is used and the identity is the code hash, which changes
# every build and silently invalidates those grants.
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --identifier io.binoio.Ensconce "$APP"

echo "Built $APP ($VERSION)"
if [[ "$IDENTITY" == "-" ]]; then
    echo "Note: ad-hoc signed. If Hide stops working after this rebuild, run ./Scripts/grant-permissions.sh"
fi
