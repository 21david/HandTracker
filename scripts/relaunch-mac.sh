#!/usr/bin/env bash
# Quit running HandTrackMac, rebuild Debug, and open the new .app so you always see the latest UI.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"

# Prefer the XcodeGen project (`project.yml` → `r.xcodeproj`).
PROJECT="r.xcodeproj"
if [[ -f project.yml ]] && command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null
fi
if [[ ! -d "$PROJECT" ]]; then
  if [[ -d HandTrack.xcodeproj ]]; then
    PROJECT="HandTrack.xcodeproj"
  else
    echo "No Xcode project found (expected r.xcodeproj)." >&2
    exit 1
  fi
fi

# AppleScript first (graceful); `killall` catches orphan/stuck launches.
osascript -e 'tell application "HandTrackMac" to if running then quit saving no' 2>/dev/null || true
sleep 0.6
killall HandTrackMac 2>/dev/null || true
pkill -x HandTrackMac 2>/dev/null || true

xcodebuild \
  -project "$PROJECT" \
  -scheme HandTrackMac \
  -destination 'platform=macOS' \
  -configuration Debug \
  build "$@"

BUILT_PRODUCTS_DIR="$(
  xcodebuild \
    -project "$PROJECT" \
    -scheme HandTrackMac \
    -configuration Debug \
    -showBuildSettings 2>/dev/null \
    | sed -n 's/^[[:space:]]*BUILT_PRODUCTS_DIR = //p' \
    | head -1
)"
APP="$BUILT_PRODUCTS_DIR/HandTrackMac.app"
if [[ ! -d "$APP" ]]; then
  echo "Built app missing: $APP" >&2
  exit 1
fi
echo "LAUNCHING $APP"
exec open "$APP"
