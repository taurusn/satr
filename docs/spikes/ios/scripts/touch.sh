#!/bin/bash
# Real touches through XCUITest: 20 pans and 10 pinch pairs on a board, the app in touch mode.
#   scripts/touch.sh sim <sim udid> [board]        (after scripts/sim-build.sh)
#   scripts/touch.sh device <xcodebuild device id> [board]   (after scripts/device-build.sh)
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
kind="$1"; id="$2"; board="${3:-big-500}"
cd "$here"
if [ "$kind" = sim ]; then
  run="$(ls build/DerivedData/Build/Products/LinenSpike_iphonesimulator*.xctestrun | head -1)"; dest="platform=iOS Simulator,id=$id"
else
  run="$(ls build/DerivedData/Build/Products/LinenSpike_iphoneos*.xctestrun | head -1)"; dest="platform=iOS,id=$id"
fi
export TEST_RUNNER_LINEN_BOARD="$board"
export TEST_RUNNER_LINEN_ATTACH="${LINEN_ATTACH:-0}"   # 1: the app is already running in touch mode
xcodebuild test-without-building -xctestrun "$run" -destination "$dest" -resultBundlePath "build/touch-$kind-$board-$(date +%H%M%S).xcresult" \
  > "build/touch-$kind-$board.txt" 2>&1 || true
grep -E "Test Case|passed|failed|error" "build/touch-$kind-$board.txt" | tail -8
