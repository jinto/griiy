#!/bin/bash
# Launch each build against a repo, time until first paint (plus the page's own
# phase timings: git, data hand-off, render), let the page auto-scroll to the end
# (frame times, DOM size, blank frames), then sum RSS of the app plus the WebKit
# helper processes it spawned (they're launchd children).
# usage: ./bench.sh <repo> [runs] [range]   e.g. ./bench.sh ~/src/linux 3 HEAD~50..HEAD
set -u
REPO=$1; RUNS=${2:-3}; RANGE=${3:-}
ROOT=$(cd "$(dirname "$0")" && pwd)
APPS=("griiy:$ROOT/target/release/griiy")
MARK=$(mktemp -u)

webkit_pids() { pgrep -f 'com.apple.WebKit\.' | sort; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }

for entry in "${APPS[@]}"; do
  name=${entry%%:*}; bin=${entry#*:}
  for i in $(seq "$RUNS"); do
    rm -f "$MARK"; before=$(webkit_pids)
    t0=$(now_ms)
    GRIIY_MARK=$MARK "$bin" -C "$REPO" ${RANGE:+"$RANGE"} >/dev/null 2>&1 &
    pid=$!
    until [ -f "$MARK" ]; do
      sleep 0.01
      [ $(( $(now_ms) - t0 )) -gt 15000 ] && { echo "$name: timeout"; break; }
    done
    ready=$(( $(now_ms) - t0 ))
    # Second line: the auto-scroll report.
    scrolled=1
    until [ "$(wc -l < "$MARK" 2>/dev/null)" -ge 2 ]; do
      sleep 0.1
      [ $(( $(now_ms) - t0 )) -gt 120000 ] && { scrolled=0; break; }
    done
    sleep 1   # let memory settle
    phases=$(sed 's/"type":"mark",//' "$MARK" 2>/dev/null | tr '\n' ' ')
    # app pid + its descendants + new WebKit helpers
    tree=$(pgrep -P $pid; for c in $(pgrep -P $pid); do pgrep -P $c; done)
    new=$(comm -13 <(echo "$before") <(webkit_pids))
    pids=$(echo $pid $tree $new | tr ' ' ',')
    rss=$(ps -o rss= -p "$pids" | awk '{s+=$1} END {printf "%.0f", s/1024}')
    nproc=$(echo $pid $tree $new | wc -w | tr -d ' ')
    # A run without the scroll report measured nothing about scrolling: say so, don't pass it off.
    [ $scrolled = 1 ] || phases="FAILED: no scroll report after 120s. $phases"
    echo "$name run$i: launch->paint=${ready}ms rss=${rss}MB procs=$nproc $phases"
    kill $pid $tree 2>/dev/null; wait $pid 2>/dev/null; sleep 1
  done
done
rm -f "$MARK"
