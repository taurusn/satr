#!/bin/bash
# Runs one spike mode on the iPhone and waits for its marker in the app's progress file, copying results back.
#   scripts/device-run.sh <CoreDevice id> <marker> <timeout s> <out dir> -LinenMode <mode> [-LinenBoard big-500] [...]
# The progress file is removed first, so an old marker never ends the wait.
core="$1"; marker="$2"; limit="$3"; out="$4"; shift 4
app=com.hatim.linen.spike-ios
mkdir -p "$out"
pull() { xcrun devicectl device copy from --device "$core" --domain-type appDataContainer --domain-identifier "$app" \
  --source "Documents/results/$1" --destination "$out/$1" >/dev/null 2>&1; }
empty="$out/.empty"; : > "$empty"
xcrun devicectl device copy to --device "$core" --domain-type appDataContainer --domain-identifier "$app" \
  --source "$empty" --destination Documents/results/progress.txt >/dev/null 2>&1
xcrun devicectl device process launch --device "$core" --terminate-existing "$app" -- "$@" 2>&1 | grep -E "Launched|error|ERROR|locked" | head -5
start=$(date +%s)
until pull progress.txt && grep -q "$marker" "$out/progress.txt" 2>/dev/null; do
  if [ $(( $(date +%s) - start )) -gt "$limit" ]; then echo "timeout after $limit s"; break; fi
  sleep 3
done
cat "$out/progress.txt"
for f in $(grep -o "results/[A-Za-z0-9-]*\.json" "$out/progress.txt" | sort -u | sed 's#results/##'); do pull "$f" && echo "pulled $out/$f"; done
