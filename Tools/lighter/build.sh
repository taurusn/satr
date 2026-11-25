#!/bin/bash
# Builds the measurement tool against a copy of LinenKit's sources (worktree state at the time of the call).
# The copy opens VaultIndex's snapshot to the tool; the product's sources are not changed.
#   build.sh <out-binary> [<LinenKit sources folder> old]   (old: the sources before this lane, with a small shim)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="${2:-$HERE/../../LinenKit/Sources/LinenKit}"
OUT="$1"
TMP="$(mktemp -d)"
cp -R "$KIT" "$TMP/LinenKit"
sed -i '' 's/    private let current: SnapshotBox/    let current: SnapshotBox/' "$TMP/LinenKit/Vault/VaultIndex.swift"
cat > "$TMP/open.swift" <<'SW'
import Foundation
extension VaultIndex { var snapshotTables: VaultTables { current.snapshot.tables } }
SW
if [ "$3" = old ]; then cat >> "$TMP/open.swift" <<'SW'
extension VaultTables { func url(of e: FileEntry) -> URL { e.url } }
extension FileEntry { init(path: String) { self.init(url: URL(fileURLWithPath: "/"), path: path) } }
extension VaultScanner { static func note(root: URL, path: String) -> NoteRecord { note(url: root.appendingPathComponent(path), path: path) } }
SW
fi
swiftc -O -swift-version 6 -enable-upcoming-feature ExistentialAny -module-name LinenKit \
  -target arm64-apple-macos15 $(find "$TMP/LinenKit" -name '*.swift') "$TMP/open.swift" "$HERE/main.swift" -o "$OUT" 2>&1 | grep -v "^$" | grep -E "error|warning: unre" | head -20
rm -rf "$TMP"
ls -la "$OUT"
