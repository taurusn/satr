#!/bin/bash
# The I(a) memory gate: xctrace's Activity Monitor template on the iPhone (all processes, about one sample a second)
# while the spike app runs the 10-minute loop. xctrace takes up to a few minutes to attach, so the loop starts only
# once xctrace says it is recording.
#   scripts/device-loop.sh <hardware id for xctrace> <CoreDevice id> <board> <minutes> <out dir>
here="$(cd "$(dirname "$0")/.." && pwd)"
hw="$1"; core="$2"; board="$3"; minutes="$4"; out="$5"
mkdir -p "$out" "$here/build"
trace="$here/build/loop-$board.trace"
rm -rf "$trace"
limit=$(( minutes * 60 + 150 ))
xcrun xctrace record --template 'Activity Monitor' --device "$hw" --all-processes --time-limit "${limit}s" --output "$trace" --no-prompt \
  > "$here/build/loop-$board-xctrace.txt" 2>&1 &
xpid=$!
echo "xctrace pid $xpid, started $(date '+%H:%M:%S')"
until grep -q "Starting recording" "$here/build/loop-$board-xctrace.txt"; do
  if ! kill -0 $xpid 2>/dev/null; then echo "xctrace ended early:"; cat "$here/build/loop-$board-xctrace.txt"; exit 1; fi
  sleep 2
done
echo "recording since $(date '+%H:%M:%S'); 15 s of baseline, then the loop"
sleep 15
bash "$here/scripts/device-run.sh" "$core" "LOOP END" $(( minutes * 60 + 120 )) "$out" -LinenMode loop -LinenBoard "$board" -LinenMinutes "$minutes" | tail -4
echo "loop ended $(date '+%H:%M:%S'); waiting for xctrace (pid $xpid) to finish its time limit"
wait $xpid
cat "$here/build/loop-$board-xctrace.txt"
xcrun xctrace export --input "$trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-live"]' > "$here/build/loop-$board-live.xml"
python3 -I "$here/scripts/am-memory.py" "$here/build/loop-$board-live.xml" --json "$out/memory-loop-$board.json"
