#!/bin/bash
# Real touches on the iPhone with an outside frame read: the app starts in touch mode, xctrace's Animation Hitches
# template attaches to it, then the UI test sends the gestures to the running app (LINEN_ATTACH=1, no relaunch).
#   scripts/device-hitches.sh <hardware id for xctrace> <CoreDevice id> <board> <out dir>
here="$(cd "$(dirname "$0")/.." && pwd)"
hw="$1"; core="$2"; board="$3"; out="$4"
trace="$here/build/hitches-$board.trace"
rm -rf "$trace"
bash "$here/scripts/device-run.sh" "$core" "TOUCH READY" 60 "$out" -LinenMode touch -LinenBoard "$board" | tail -1
pid=$(xcrun devicectl device info processes --device "$core" 2>/dev/null | grep "LinenSpike.app/LinenSpike" | awk '{print $1}' | head -1)
echo "app pid on the phone: $pid"
xcrun xctrace record --template 'Animation Hitches' --device "$hw" --attach "$pid" --time-limit 200s --output "$trace" --no-prompt \
  > "$here/build/hitches-$board-xctrace.txt" 2>&1 &
xpid=$!
until grep -q "Starting recording" "$here/build/hitches-$board-xctrace.txt"; do
  if ! kill -0 $xpid 2>/dev/null; then echo "xctrace ended early:"; cat "$here/build/hitches-$board-xctrace.txt"; exit 1; fi
  sleep 2
done
echo "recording since $(date '+%H:%M:%S')"
sleep 3
LINEN_ATTACH=1 bash "$here/scripts/touch.sh" device "$core" "$board" | tail -3
echo "gestures done $(date '+%H:%M:%S'); stopping xctrace (pid $xpid) with SIGINT"
kill -INT $xpid
wait $xpid
tail -3 "$here/build/hitches-$board-xctrace.txt"
xcrun devicectl device copy from --device "$core" --domain-type appDataContainer --domain-identifier com.hatim.linen.spike-ios \
  --source "Documents/results/touch-$board.json" --destination "$out/touch-$board.json" >/dev/null 2>&1 && echo "pulled $out/touch-$board.json"
xcrun xctrace export --input "$trace" --toc > "$here/build/hitches-$board-toc.xml"
grep -o 'schema="[^"]*"' "$here/build/hitches-$board-toc.xml" | sort -u
