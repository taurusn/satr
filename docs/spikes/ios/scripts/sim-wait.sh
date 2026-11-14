#!/bin/bash
# Waits until the spike app on the simulator writes "DONE" (or a given marker) in its progress file, then prints it.
#   scripts/sim-wait.sh <sim udid> [marker] [timeout s]
sim="$1"; marker="${2:-DONE}"; limit="${3:-600}"
dir="$(xcrun simctl get_app_container "$sim" com.hatim.linen.spike-ios data)/Documents/results"
start=$(date +%s)
until grep -q "$marker" "$dir/progress.txt" 2>/dev/null; do
  if [ $(( $(date +%s) - start )) -gt "$limit" ]; then echo "timeout after $limit s"; break; fi
  sleep 2
done
cat "$dir/progress.txt"
echo "results: $dir"
