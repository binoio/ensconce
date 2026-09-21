#!/bin/zsh
# Runs the unit tests. Must run on macOS: the library links CoreGraphics, which
# has no Linux implementation, so a Docker (Linux) container cannot build it.
# For CI, use a macOS runner and set CI=1 so the live-window-server test skips.
#
# The suite is XCTest-only; swift-testing's helper is disabled because it
# cannot dlopen the ad-hoc-signed bundle from a quarantined checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
swift test --enable-xctest --disable-swift-testing "$@"
