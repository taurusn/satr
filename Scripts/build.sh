#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
build_root="$project_root/build"
app_bundle="$build_root/Satr.app"
contents="$app_bundle/Contents"
macos_dir="$contents/MacOS"
resources_dir="$contents/Resources"
vendor_dir="$project_root/Resources/vendor"
install_app="/Applications/Satr.app"

for required in "$vendor_dir/marked.js" "$vendor_dir/purify.min.js" "$vendor_dir/mermaid.min.js"; do
  if [[ ! -f "$required" ]]; then
    echo "Missing renderer dependency: $required" >&2
    echo "Run npm install, then copy the browser bundles into Resources/vendor." >&2
    exit 1
  fi
done

if [[ -d "$build_root" ]]; then
  rm -rf "$build_root"
fi
mkdir -p "$macos_dir" "$resources_dir"

swift_sources=("$project_root"/Sources/Satr/*.swift)
xcrun swiftc \
  -swift-version 5 \
  -O \
  -whole-module-optimization \
  -target arm64-apple-macos14.0 \
  -framework AppKit \
  -framework WebKit \
  -framework UniformTypeIdentifiers \
  "${swift_sources[@]}" \
  -o "$macos_dir/Satr"

cp "$project_root/Info.plist" "$contents/Info.plist"
cp "$project_root/Resources/reader.html" "$resources_dir/reader.html"
cp "$project_root/Resources/reader.css" "$resources_dir/reader.css"
cp "$project_root/Resources/reader.js" "$resources_dir/reader.js"
cp "$vendor_dir/marked.js" "$resources_dir/marked.js"
cp "$vendor_dir/purify.min.js" "$resources_dir/purify.min.js"
cp "$vendor_dir/mermaid.min.js" "$resources_dir/mermaid.min.js"

icon_source="$build_root/AppIcon-1024.png"
iconset="$build_root/AppIcon.iconset"
xcrun swift "$project_root/Scripts/make_icon.swift" "$icon_source"
mkdir -p "$iconset"
for spec in \
  '16 icon_16x16.png' \
  '32 icon_16x16@2x.png' \
  '32 icon_32x32.png' \
  '64 icon_32x32@2x.png' \
  '128 icon_128x128.png' \
  '256 icon_128x128@2x.png' \
  '256 icon_256x256.png' \
  '512 icon_256x256@2x.png' \
  '512 icon_512x512.png' \
  '1024 icon_512x512@2x.png'; do
  pixels="${spec%% *}"
  filename="${spec#* }"
  sips -z "$pixels" "$pixels" "$icon_source" --out "$iconset/$filename" >/dev/null
done
iconutil -c icns "$iconset" -o "$resources_dir/AppIcon.icns"

plutil -lint "$contents/Info.plist"
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"

if [[ "${1:-}" == "--install" ]]; then
  if [[ -e "$install_app" ]]; then
    if [[ "$install_app" != "/Applications/Satr.app" ]]; then
      echo "Refusing to replace unexpected app path: $install_app" >&2
      exit 1
    fi
    rm -rf "$install_app"
  fi
  ditto "$app_bundle" "$install_app"
  codesign --verify --deep --strict "$install_app"
  echo "Installed $install_app"
else
  echo "Built $app_bundle"
fi
