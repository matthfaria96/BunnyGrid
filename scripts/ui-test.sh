#!/bin/zsh
# Runs the in-app UI scenarios (scripts/ui-scenarios/*.json) against the debug build and prints pass/fail.
# Usage: scripts/ui-test.sh [--no-build] [scenario-name…]      (default: every scenario)
# Each run gets a fresh scratch data dir, an in-memory Keychain and a copy of Resources/Samples/demo.sqlite;
# events are synthesized inside the app (UIHarness.swift), so the real pointer and other apps are never touched.
# Env: UI_TEST_OUT (results/screenshots, default $TMPDIR/bunnygrid-ui-test), UI_TEST_TIMEOUT (s, default 180),
#      BUNNYGRID_DEBUG_PASSWORD for scenarios that need throwaway servers ("requires" in the scenario).
set -uo pipefail

ROOT="${0:A:h:h}"
SCENARIOS="$ROOT/scripts/ui-scenarios"
OUT="${UI_TEST_OUT:-${TMPDIR:-/tmp}/bunnygrid-ui-test}"
TIMEOUT="${UI_TEST_TIMEOUT:-180}"
APP="$ROOT/build/BunnyGrid.app/Contents/MacOS/BunnyGrid"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

BUILD=1
NAMES=()
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    *) NAMES+=("${arg%.json}") ;;
  esac
done
if (( BUILD )); then "$ROOT/scripts/bundle.sh" debug >/dev/null || { echo "build failed"; exit 2; }; fi
if (( ${#NAMES} == 0 )); then
  for file in "$SCENARIOS"/*.json; do NAMES+=("${${file:t}%.json}"); done
fi

mkdir -p "$OUT"
passed=0; failed=0; skipped=0
FAILED=()
for name in "${NAMES[@]}"; do
  file="$SCENARIOS/$name.json"
  [[ -f "$file" ]] || { echo "?? $name (no such scenario)"; failed=$((failed+1)); FAILED+=("$name"); continue; }
  # Launch flags and requirements come from the scenario ("args", "requires": ["postgres", …], "fixture").
  meta=("${(@f)$(/usr/bin/python3 -I - "$file" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(" ".join(s.get("requires", [])))
print(s.get("fixture", "demo"))
for a in s.get("args", []): print(a)
PY
)}")
  requires="${meta[1]}"; fixture="${meta[2]}"; args=("${(@)meta[3,-1]}")
  missing=""
  for need in ${=requires}; do
    case "$need" in
      postgres) pg_isready -q -h 127.0.0.1 -p "${UI_TEST_PG_PORT:-55432}" 2>/dev/null || missing+=" postgres" ;;
      mysql) nc -z 127.0.0.1 "${UI_TEST_MYSQL_PORT:-53306}" 2>/dev/null || missing+=" mysql" ;;
      mongo) nc -z 127.0.0.1 "${UI_TEST_MONGO_PORT:-57017}" 2>/dev/null || missing+=" mongo" ;;
      redis) nc -z 127.0.0.1 "${UI_TEST_REDIS_PORT:-56379}" 2>/dev/null || missing+=" redis" ;;
      mock-ai) ;;
    esac
  done
  if [[ -n "$missing" ]]; then echo "-- $name (skipped: no$missing)"; skipped=$((skipped+1)); continue; fi

  run="$OUT/$name"
  rm -rf "$run"; mkdir -p "$run/data" "$run/shots"
  cp "$ROOT/Resources/Samples/demo.sqlite" "$run/demo.sqlite"
  # A scenario may seed the data dir (connections.json with {{PORT}} placeholders) from scripts/ui-scenarios/fixtures.
  if [[ "$fixture" != "demo" && -d "$SCENARIOS/fixtures/$fixture" ]]; then
    for f in "$SCENARIOS/fixtures/$fixture"/*; do
      sed -e "s|{{PG_PORT}}|${UI_TEST_PG_PORT:-55432}|g" -e "s|{{MYSQL_PORT}}|${UI_TEST_MYSQL_PORT:-53306}|g" \
          -e "s|{{MONGO_PORT}}|${UI_TEST_MONGO_PORT:-57017}|g" -e "s|{{REDIS_PORT}}|${UI_TEST_REDIS_PORT:-56379}|g" \
          -e "s|{{RUN}}|$run|g" "$f" > "$run/data/${f:t}"
    done
  fi
  mock_pid=""
  if [[ " $requires " == *" mock-ai "* ]]; then
    /usr/bin/python3 -I "$ROOT/scripts/ui-scenarios/mock-ai.py" 58989 > "$run/mock-ai.log" 2>&1 &
    mock_pid=$!
    sleep 0.5
  fi
  # {{DB}} in args is this run's demo.sqlite copy; {{RUN}} its directory.
  final=()
  for a in "${args[@]}"; do a="${a//\{\{DB\}\}/$run/demo.sqlite}"; final+=("${a//\{\{RUN\}\}/$run}"); done
  (
    cd "$run"
    BUNNYGRID_DATA_DIR="$run/data" BUNNYGRID_MEMORY_KEYCHAIN=1 \
    BUNNYGRID_ANTHROPIC_BASE_URL="http://127.0.0.1:58989" BUNNYGRID_OPENAI_BASE_URL="http://127.0.0.1:58989" \
    "$APP" "${final[@]}" -AppleLanguages '(en)' -AppleLocale en_US -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO \
      --ui-script "$file" --ui-results "$run/results.json" --ui-shots "$run/shots" > "$run/app.log" 2>&1 &
    pid=$!
    for ((i = 0; i < TIMEOUT * 10; i++)); do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
    if kill -0 $pid 2>/dev/null; then echo "timeout" > "$run/timeout"; kill $pid; sleep 0.5; kill -9 $pid 2>/dev/null; fi
    wait $pid 2>/dev/null
    echo $? > "$run/exit"
  )
  [[ -n "$mock_pid" ]] && kill $mock_pid 2>/dev/null
  code=$(cat "$run/exit")
  if [[ -f "$run/results.json" ]] && /usr/bin/python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["passed"] else 1)' "$run/results.json"; then
    echo "ok $name"
    passed=$((passed+1))
  else
    failed=$((failed+1)); FAILED+=("$name")
    if [[ -f "$run/timeout" ]]; then reason="timed out"
    elif [[ ! -f "$run/results.json" ]]; then reason="crashed (exit $code), see $run/app.log"
    else reason=$(/usr/bin/python3 -I -c '
import json,sys
r = json.load(open(sys.argv[1]))
bad = [s for s in r["steps"] if not s["ok"]]
b = bad[0] if bad else None
print(r.get("fatal") or ("step %s %s %s: %s" % (b["index"], b["op"], b.get("note") or "", b.get("error")) if b else "failed"))' "$run/results.json")
    fi
    echo "FAIL $name: $reason"
  fi
done
echo "$passed passed, $failed failed, $skipped skipped  (results in $OUT)"
(( failed == 0 ))
