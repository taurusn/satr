#!/bin/bash
# Builds the spike app and its UI tests (Release) for the simulator and installs the app.
#   scripts/sim-build.sh <sim udid>
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
sim="$1"
cd "$here"
xcodegen generate >/dev/null
xcodebuild -project LinenSpike.xcodeproj -scheme LinenSpike -configuration Release -derivedDataPath build/DerivedData \
  -destination "platform=iOS Simulator,id=$sim" build-for-testing > build/sim-build.txt 2>&1 || { grep -E "error:" build/sim-build.txt | head -20; exit 1; }
grep -E "\*\* .* \*\*" build/sim-build.txt
xcrun simctl install "$sim" build/DerivedData/Build/Products/Release-iphonesimulator/LinenSpike.app
echo "installed on $sim"
