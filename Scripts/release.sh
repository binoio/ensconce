#!/bin/zsh
#
# release.sh: Build, sign, notarize (App Store Connect API), EdDSA-sign,
# and publish an Ensconce release with an updated Sparkle appcast.
#
# One-time setup:
#   1. App Store Connect API key: xcrun notarytool store-credentials ensconce-notary \
#        --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#      (any same-team profile such as kona-notary is picked up automatically)
#   2. Sparkle EdDSA key pair in the login Keychain (bin/generate_keys). The
#      public half must match SUPublicEDKey in Resources/Info.plist.
#   3. gh auth login with access to binoio/ensconce.

set -euo pipefail

IDENTITY="${ENSCONCE_SIGN_IDENTITY:-Developer ID Application: Michael Bino (43L352U8Y8)}"
REPO="binoio/ensconce"
BUNDLE_ID="io.binoio.Ensconce"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Resolve the notarytool keychain profile: explicit env var, then ensconce-notary,
# then any same-team profile.
NOTARY_PROFILE=""
for candidate in "${ENSCONCE_NOTARY_PROFILE:-}" ensconce-notary kona-notary lincoln-notary atmo-notary edith-notary outsight-notary; do
    [[ -n "$candidate" ]] || continue
    if xcrun notarytool history --keychain-profile "$candidate" >/dev/null 2>&1; then
        NOTARY_PROFILE="$candidate"
        break
    fi
done
[[ -n "$NOTARY_PROFILE" ]] || { echo "error: no notarytool keychain profile found (run: xcrun notarytool store-credentials ensconce-notary ...)" >&2; exit 1; }

VERSION=$(tr -d '[:space:]' < VERSION)
TAG="v${VERSION}"
APP="build/Ensconce.app"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
ZIP="build/Ensconce-${VERSION}.zip"
NOTES_MD="ReleaseNotes/Ensconce-${VERSION}.md"
NOTES_HTML="ReleaseNotes/Ensconce-${VERSION}.html"

echo "==> Preflight for Ensconce ${VERSION}"
[[ -z "$(git status --porcelain)" ]] || { echo "error: working tree not clean" >&2; exit 1; }
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists" >&2; exit 1
fi
LATEST_TAG=$(git tag -l 'v*' | sort -V | tail -1)
if [[ -n "$LATEST_TAG" && "$(print -l "$LATEST_TAG" "$TAG" | sort -V | tail -1)" != "$TAG" ]]; then
    echo "error: VERSION ($VERSION) is not newer than latest tag ($LATEST_TAG)" >&2; exit 1
fi
[[ -f "$NOTES_MD" ]] || { echo "error: $NOTES_MD missing" >&2; exit 1; }
[[ -f "$NOTES_HTML" ]] || { echo "error: $NOTES_HTML missing" >&2; exit 1; }
security find-identity -v -p codesigning | grep -q "Developer ID Application" || {
    echo "error: no Developer ID Application signing identity in keychain" >&2; exit 1
}
gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated" >&2; exit 1; }

echo "==> Building"
CODESIGN_IDENTITY="$IDENTITY" ./Scripts/build.sh release

SPARKLE_BIN=$(find .build/artifacts -type d -name bin -path "*parkle*" | head -1)
[[ -n "$SPARKLE_BIN" ]] || { echo "error: Sparkle tools not found under .build/artifacts" >&2; exit 1; }

echo "==> Verifying bundle"
PLIST="$APP/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")" == "$BUNDLE_ID" ]] || { echo "error: wrong bundle id" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")" == "$VERSION" ]] || { echo "error: bundle version != VERSION" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$PLIST")" == https://* ]] || { echo "error: SUFeedURL missing or not https" >&2; exit 1; }
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$PLIST")"
[[ -n "$PUBLIC_KEY" ]] || { echo "error: SUPublicEDKey missing" >&2; exit 1; }
KEYCHAIN_KEY="$("$SPARKLE_BIN/generate_keys" -p)"
[[ "$PUBLIC_KEY" == "$KEYCHAIN_KEY" ]] || { echo "error: SUPublicEDKey ($PUBLIC_KEY) does not match the EdDSA key in the login Keychain ($KEYCHAIN_KEY)" >&2; exit 1; }
if /usr/libexec/PlistBuddy -c 'Print SUEnableAutomaticChecks' "$PLIST" >/dev/null 2>&1; then
    echo "error: SUEnableAutomaticChecks must not be set (breaks first-run prompt)" >&2; exit 1
fi
[[ -d "$FRAMEWORK" ]] || { echo "error: Sparkle.framework not embedded" >&2; exit 1; }
otool -l "$APP/Contents/MacOS/Ensconce" | grep -q "@executable_path/../Frameworks" || { echo "error: Frameworks rpath missing" >&2; exit 1; }

echo "==> Codesigning (inside-out; never --deep)"
codesign -f -s "$IDENTITY" -o runtime "$FRAMEWORK/Versions/B/Autoupdate"
codesign -f -s "$IDENTITY" -o runtime "$FRAMEWORK/Versions/B/Updater.app"
codesign -f -s "$IDENTITY" -o runtime --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign -f -s "$IDENTITY" -o runtime --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign -f -s "$IDENTITY" -o runtime "$FRAMEWORK"
codesign -f -s "$IDENTITY" -o runtime --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Notarizing via App Store Connect API ($NOTARY_PROFILE)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Generating appcast (EdDSA signature from login Keychain)"
WORK="build/appcast-work"
rm -rf "$WORK"
mkdir -p "$WORK"
cp "$ZIP" "$WORK/"
cp "$NOTES_HTML" "$WORK/Ensconce-${VERSION}.html"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" \
    --embed-release-notes \
    -o docs/appcast.xml "$WORK"

echo "==> Publishing (release first so the asset exists before the appcast goes live)"
git tag "$TAG"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "Ensconce ${VERSION}" --notes-file "$NOTES_MD"

git add docs/appcast.xml
git commit -m "Publish appcast for ${VERSION}"
git push origin HEAD

echo "==> Done: Ensconce ${VERSION} released. Pages will deploy the appcast shortly."
