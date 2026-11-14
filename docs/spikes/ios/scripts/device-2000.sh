#!/bin/bash
# The 2,000-node board on the iPhone under xctrace's Activity Monitor: the renderer bench, then real touches, then a
# short loop, so web content memory is known while it pans and zooms (PRD-2 section 4: under 300 MB).
#   scripts/device-2000.sh <hardware id for xctrace> <CoreDevice id> <loop minutes> <out dir>
here="$(cd "$(dirname "$0")/.." && pwd)"
hw="$1"; core="$2"; minutes="$3"; out="$4"
board=big-2000
trace="$here/build/am-$board.trace"
rm -rf "$trace"
xcrun xctrace record --template 'Activity Monitor' --device "$hw" --all-processes --time-limit 1500s --output "$trace" --no-prompt \
  > "$here/build/am-$board-xctrace.txt" 2>&1 &
xpid=$!
until grep -q "Starting recording" "$here/build/am-$board-xctrace.txt"; do
  if ! kill -0 $xpid 2>/dev/null; then echo "xctrace ended early:"; cat "$here/build/am-$board-xctrace.txt"; exit 1; fi
  sleep 2
done
echo "recording since $(date '+%H:%M:%S')"
sleep 10
echo "bench $(date '+%H:%M:%S')"
bash "$here/scripts/device-run.sh" "$core" DONE 600 "$out" -LinenMode bench -LinenBoard "$board" | tail -2
echo "touch $(date '+%H:%M:%S')"
bash "$here/scripts/touch.sh" device "$core" "$board" | tail -2
xcrun devicectl device copy from --device "$core" --domain-type appDataContainer --domain-identifier com.hatim.linen.spike-ios \
  --source "Documents/results/touch-$board.json" --destination "$out/touch-$board.json" >/dev/null 2>&1 && echo "pulled $out/touch-$board.json"
echo "loop $(date '+%H:%M:%S')"
bash "$here/scripts/device-run.sh" "$core" "LOOP END" $(( minutes * 60 + 120 )) "$out" -LinenMode loop -LinenBoard "$board" -LinenMinutes "$minutes" | tail -3
echo "done $(date '+%H:%M:%S'); stopping xctrace"
kill -INT $xpid
wait $xpid
tail -2 "$here/build/am-$board-xctrace.txt"
xcrun xctrace export --input "$trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-live"]' > "$here/build/am-$board-live.xml"
python3 -I "$here/scripts/am-memory.py" "$here/build/am-$board-live.xml" --json "$out/memory-$board.json"
