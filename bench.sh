#!/bin/bash
# Launch each build against a repo, time until first paint (plus the page's own
# phase timings: git, data hand-off, render), sum RSS of the
# app plus the WebKit helper processes it spawned (they're launchd children).
# usage: ./bench.sh <repo> [runs]
set -u
REPO=$1; RUNS=${2:-3}
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
    GRIIY_MARK=$MARK "$bin" "$REPO" >/dev/null 2>&1 &
    pid=$!
    until [ -f "$MARK" ]; do
      sleep 0.01
      [ $(( $(now_ms) - t0 )) -gt 15000 ] && { echo "$name: timeout"; break; }
    done
    ready=$(( $(now_ms) - t0 ))
    sleep 2   # let memory settle after first paint
    phases=$(cat "$MARK" 2>/dev/null)
    # app pid + its descendants + new WebKit helpers
    tree=$(pgrep -P $pid; for c in $(pgrep -P $pid); do pgrep -P $c; done)
    new=$(comm -13 <(echo "$before") <(webkit_pids))
    pids=$(echo $pid $tree $new | tr ' ' ',')
    rss=$(ps -o rss= -p "$pids" | awk '{s+=$1} END {printf "%.0f", s/1024}')
    nproc=$(echo $pid $tree $new | wc -w | tr -d ' ')
    echo "$name run$i: launch->paint=${ready}ms rss=${rss}MB procs=$nproc $phases"
    kill $pid $tree 2>/dev/null; wait $pid 2>/dev/null; sleep 1
  done
done
rm -f "$MARK"
