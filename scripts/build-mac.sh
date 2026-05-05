#!/usr/bin/env bash
# Build HandTrackMac from Cursor terminal (captures compiler output for the AI / logs).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$ROOT"
xcodebuild \
  -project HandTrack.xcodeproj \
  -scheme HandTrackMac \
  -destination 'platform=macOS' \
  -configuration Debug \
  build "$@"
