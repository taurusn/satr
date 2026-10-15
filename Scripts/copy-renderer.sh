#!/bin/bash
# Copies Linen's renderer into a built bundle, and the Thmanyah faces from ~/Library/Fonts beside it.
# The fonts are never in the source tree: their license forbids hosting them (docs/PRD.md section 11).
set -euo pipefail
src="$(cd "$(dirname "$0")/.." && pwd)/Renderer"
dest="$1"
mkdir -p "$dest/fonts"
rsync -a --delete --exclude fonts --exclude '.DS_Store' "$src/" "$dest/"
# The agents' format guide travels with the renderer: `linen mcp` serves it (linen_guide).
cp "$src/../docs/FORMAT.md" "$dest/FORMAT.md"
mkdir -p "$dest/fonts"
for f in thmanyahsans-Regular thmanyahsans-Medium thmanyahsans-Bold thmanyahserifdisplay-Light thmanyahseriftext-Regular thmanyahseriftext-Medium; do
  if [ -f "$HOME/Library/Fonts/$f.otf" ]; then cp "$HOME/Library/Fonts/$f.otf" "$dest/fonts/"; else echo "warning: $f.otf not installed; Linen falls back to system faces" >&2; fi
done
