#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build.sh "${1:-debug}"
open build/Ensconce.app
