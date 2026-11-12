#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift test --package-path "$ROOT"
if [[ "${HARBOR_LIVE_TESTS:-0}" == 1 ]]; then
  print 'Live tests enabled: read-only requests to Bilibili and short AVPlayer playback.'
fi
plutil -lint "$ROOT/Scripts/Info.plist" "$ROOT/Scripts/HarborBili.entitlements"
