#!/bin/bash
# Runs one spike mode on the simulator and waits for its marker.
#   scripts/sim-run.sh <sim udid> <marker> <timeout s> -LinenMode <mode> [-LinenBoard big-500] [...]
sim="$1"; marker="$2"; limit="$3"; shift 3
dir="$(xcrun simctl get_app_container "$sim" com.hatim.linen.spike-ios data)/Documents/results"
rm -f "$dir/progress.txt"
xcrun simctl launch --terminate-running-process "$sim" com.hatim.linen.spike-ios "$@"
start=$(date +%s)
until grep -q "$marker" "$dir/progress.txt" 2>/dev/null; do
  if [ $(( $(date +%s) - start )) -gt "$limit" ]; then echo "timeout after $limit s"; break; fi
  sleep 2
done
cat "$dir/progress.txt"
echo "results: $dir"
