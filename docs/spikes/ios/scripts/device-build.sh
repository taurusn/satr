#!/bin/bash
# Builds the spike app and its UI tests (Release) for the iPhone and installs the app with devicectl.
#   scripts/device-build.sh <xcodebuild destination id> <CoreDevice id>
# The iPhone "Eight": CoreDevice <coredevice-id>, hardware <hardware-id>. Never by name.
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
dest="$1"; core="$2"
cd "$here"
xcodegen generate >/dev/null
xcodebuild -project LinenSpike.xcodeproj -scheme LinenSpike -configuration Release -derivedDataPath build/DerivedData \
  -allowProvisioningUpdates -destination "platform=iOS,id=$dest" build-for-testing > build/device-build.txt 2>&1 \
  || { grep -E "error:|Signing|provision" build/device-build.txt | head -20; exit 1; }
grep -E "\*\* .* \*\*" build/device-build.txt
xcrun devicectl device install app --device "$core" build/DerivedData/Build/Products/Release-iphoneos/LinenSpike.app 2>&1 | tail -3
