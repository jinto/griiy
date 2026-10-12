#!/bin/bash
# Spike bench (docs/SPIKE-native-ui.md): runs each app against each repo, in a shuffled order
# per round, and reports per run:
#   paint  = launch → first paint, from the app's own wall clock in mark line 1 (no polling error)
#   fp     = physical footprint (/usr/bin/footprint) summed over the app and, for WebKit, its 3 new
#            helpers; median of 3 samples taken after a 5 s settle that follows the auto-scroll
#   rss    = plain RSS sum of the same processes, for reference (double-counts shared pages)
#   scroll = mark line 2 as the app reports it
# usage: spike/bench.sh <rounds> <name=binary>... -- <repo[:range]>...
set -u
ROUNDS=$1; shift
APPS=(); while [ "$1" != "--" ]; do APPS+=("$1"); shift; done; shift
REPOS=("$@")
MARK=$(mktemp -u)
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
webkit_pids() { pgrep -f 'com.apple.WebKit\.' | sort; }
fp_mb() { /usr/bin/footprint --noCategories -f bytes $(for p in "$@"; do echo -p $p; done) 2>/dev/null |
  awk '$1 == "phys_footprint:" {s += $2} END {printf "%.0f", s/1048576}'; }
median3() { printf '%s\n' "$@" | sort -n | sed -n 2p; }

for round in $(seq "$ROUNDS"); do
  for entry in $(printf '%s\n' "${APPS[@]}" | perl -MList::Util=shuffle -e 'print shuffle <STDIN>'); do
    name=${entry%%=*}; bin=${entry#*=}
    for spec in "${REPOS[@]}"; do
      repo=${spec%%:*}; range=${spec#*:}; [ "$range" = "$spec" ] && range=""
      rm -f "$MARK"; before=$(webkit_pids)
      t0=$(now_ms)
      GRIIY_MARK=$MARK "$bin" -C "$repo" ${range:+"$range"} >/dev/null 2>&1 &
      pid=$!
      status=ok
      until [ -f "$MARK" ] && [ "$(wc -l < "$MARK")" -ge 2 ]; do
        sleep 0.1; [ $(( $(now_ms) - t0 )) -gt 150000 ] && { status="FAILED(no scroll report)"; break; }
      done
      sleep 5
      new=$(comm -13 <(echo "$before") <(webkit_pids))
      nnew=$(echo $new | wc -w | tr -d ' ')
      [ "$nnew" -ne 0 ] && [ "$nnew" -ne 3 ] && status="FAILED($nnew new WebKit helpers)"
      pids="$pid $(pgrep -P $pid | tr '\n' ' ') $new"
      s1=$(fp_mb $pids); sleep 1; s2=$(fp_mb $pids); sleep 1; s3=$(fp_mb $pids)
      rss=$(ps -o rss= -p "$(echo $pids | tr ' ' ',')" | awk '{s+=$1} END {printf "%.0f", s/1024}')
      wall=$(head -1 "$MARK" 2>/dev/null | sed -n 's/.*"wall":\([0-9]*\).*/\1/p')
      paint=$([ -n "$wall" ] && echo $(( wall - t0 )) || echo "?")
      scroll=$(sed -n 2p "$MARK" 2>/dev/null | sed 's/"type":"mark",//')
      echo "round=$round app=$name repo=$(basename "$repo") paint=${paint}ms fp=$(median3 $s1 $s2 $s3)MB rss=${rss}MB status=$status first=$(head -1 "$MARK" 2>/dev/null | sed 's/"type":"mark",//') scroll=$scroll"
      kill $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 1
    done
  done
done
rm -f "$MARK"
