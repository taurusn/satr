#!/bin/bash
# Spike B(a): runs board.html's scripted pan and zoom in the iOS simulator's Safari, headless (Simulator.app stays
# closed), once per case, and prints each report. serve.py must be running on 48720 and the simulator booted
# (xcrun simctl boot <udid>). A case is board.html's query string without bench=1.
#   bash docs/spikes/boards/sim-bench.sh <udid> <report-file> "n=500&v=1" "n=500&v=3" "n=2000&v=3&ns=0"
UDID="$1"; OUT="$2"; shift 2
touch "$OUT"
for q in "$@"; do
  before=$(wc -l < "$OUT")
  xcrun simctl openurl "$UDID" "http://127.0.0.1:48720/board.html?$q&bench=1&r=$RANDOM"
  got=""
  for i in $(seq 1 150); do
    sleep 2
    if [ "$(wc -l < "$OUT")" -gt "$before" ]; then got=1; break; fi
  done
  echo "== $q"
  if [ -n "$got" ]; then tail -1 "$OUT"; else echo "no report within 300 s"; fi
  sleep 2
done
