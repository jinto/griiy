#!/bin/bash
# Smoke test (PLAN-swift): quitting the app while git is still opening the review leaves no git,
# and no child of git, behind. git is a fake on PATH that starts a long sleep and waits for it.
set -u
cd "$(dirname "$0")/.."
dir=$(mktemp -d)
printf '#!/bin/sh\nsleep 47 &\nwait\n' > "$dir/git" && chmod +x "$dir/git"
printf 'import AppKit\nexit(NSRunningApplication(processIdentifier: pid_t(CommandLine.arguments[1]) ?? 0)?.terminate() == true ? 0 : 1)\n' > "$dir/quit.swift"
PATH="$dir:$PATH" .build/release/griiy -C . & app=$!
sleep 2
before=$(pgrep -f 'sleep 47' | wc -l | tr -d ' ')
swift "$dir/quit.swift" "$app"   # the same path as ⌘Q: applicationShouldTerminate
sleep 1.5
after=$(pgrep -f 'sleep 47' | wc -l | tr -d ' ')
pkill -f 'sleep 47'; kill "$app" 2>/dev/null; rm -rf "$dir"
if [ "$before" = 1 ] && [ "$after" = 0 ]; then echo "ok: git and its child are gone after quit"; else echo "FAILED: before=$before after=$after"; exit 1; fi
