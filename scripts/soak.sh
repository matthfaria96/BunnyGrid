#!/bin/zsh
# Long-session soak: runs scripts/ui-scenarios/soak.json (200 tabs opened and closed, 500 queries, tab switching,
# scrolling, every Tools wizard) in the debug build, then runs `leaks`, `heap` and `footprint`
# on the still-running app and prints the memory samples and the main-thread hang summary.
# Usage: scripts/soak.sh [--no-build] [scenario]     Env: SOAK_OUT (default $TMPDIR/bunnygrid-soak)
set -uo pipefail
ROOT="${0:A:h:h}"
OUT="${SOAK_OUT:-${TMPDIR:-/tmp}/bunnygrid-soak}"
NAME=soak
BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    *) NAME="${arg%.json}" ;;
  esac
done
[[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
if (( BUILD )); then "$ROOT/scripts/bundle.sh" debug >/dev/null || { echo "build failed"; exit 2; }; fi

rm -rf "$OUT"; mkdir -p "$OUT/data" "$OUT/shots"
cp "$ROOT/Resources/Samples/demo.sqlite" "$OUT/demo.sqlite"
TEST_ID="app.bunnygrid.BunnyGrid.uitest"
ditto "$ROOT/build/BunnyGrid.app" "$OUT/BunnyGridUITest.app"
plutil -replace CFBundleIdentifier -string "$TEST_ID" "$OUT/BunnyGridUITest.app/Contents/Info.plist"
codesign --force --sign - "$OUT/BunnyGridUITest.app" >/dev/null 2>&1
defaults delete "$TEST_ID" >/dev/null 2>&1

cd "$OUT"
# SOAK_STACKS=1 records allocation stacks for `leaks` (it inflates the footprint, so memory numbers are taken without it).
stacks=()
[[ -n "${SOAK_STACKS:-}" ]] && stacks=(MallocStackLogging=1)
env "${stacks[@]}" BUNNYGRID_DATA_DIR="$OUT/data" BUNNYGRID_MEMORY_KEYCHAIN=1 BUNNYGRID_UI_RUN="$OUT" \
BUNNYGRID_LAUNCH_AGENTS_DIR="$OUT/agents" \
  "$OUT/BunnyGridUITest.app/Contents/MacOS/BunnyGrid" "$OUT/demo.sqlite" --window-size 1400x900 \
  -AppleLanguages '(en)' -AppleLocale en_US -ApplePersistenceIgnoreState YES \
  --ui-script "$ROOT/scripts/ui-scenarios/$NAME.json" --ui-results "$OUT/results.json" --ui-shots "$OUT/shots" --ui-keep-open \
  > "$OUT/app.log" 2>&1 &
pid=$!
for ((i = 0; i < 9000; i++)); do [[ -f "$OUT/results.json" ]] && break; kill -0 $pid 2>/dev/null || break; sleep 0.2; done
sleep 2
if kill -0 $pid 2>/dev/null; then
  leaks $pid > "$OUT/leaks.txt" 2>&1
  footprint $pid > "$OUT/footprint.txt" 2>&1
  heap $pid > "$OUT/heap.txt" 2>&1
  kill $pid
fi
/usr/bin/python3 -I -c '
import json, sys
r = json.load(open(sys.argv[1]))
print("passed" if r["passed"] else "FAILED: %s" % (r.get("fatal") or [s for s in r["steps"] if not s["ok"]][:1]))
for line in r["logs"]: print("  " + line)' "$OUT/results.json" 2>/dev/null || echo "no results (see $OUT/app.log)"
grep -E "^Process .*: [0-9]+ leaks? for" "$OUT/leaks.txt" 2>/dev/null
grep -E "Footprint|phys_footprint" "$OUT/footprint.txt" 2>/dev/null | head -3
# Live app objects after every tab was closed: tab models, drivers and grids should not pile up.
awk '$NF == "BunnyGrid" && $4 ~ /(TabModel|Driver|GridTableView|GridRowView|PaddedTextField|Session|DatabaseContext)$/ { print "  " $4 ": " $1 }' \
  "$OUT/heap.txt" 2>/dev/null
echo "details: $OUT"
