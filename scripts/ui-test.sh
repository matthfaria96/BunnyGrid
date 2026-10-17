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
APP=""
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
# A copy with its own bundle identifier, so scenarios never read or write the real app's preferences
# (UserDefaults); they are wiped before every scenario.
mkdir -p "$OUT"
TEST_ID="app.bunnygrid.BunnyGrid.uitest"
rm -rf "$OUT/BunnyGridUITest.app"
ditto "$ROOT/build/BunnyGrid.app" "$OUT/BunnyGridUITest.app"
plutil -replace CFBundleIdentifier -string "$TEST_ID" "$OUT/BunnyGridUITest.app/Contents/Info.plist"
plutil -replace CFBundleName -string "BunnyGrid UI Test" "$OUT/BunnyGridUITest.app/Contents/Info.plist"
codesign --force --sign - "$OUT/BunnyGridUITest.app" >/dev/null 2>&1
APP="$OUT/BunnyGridUITest.app/Contents/MacOS/BunnyGrid"
if (( ${#NAMES} == 0 )); then
  for file in "$SCENARIOS"/*.json; do NAMES+=("${${file:t}%.json}"); done
fi

mkdir -p "$OUT"
passed=0; failed=0; skipped=0; xfailed=0
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
print("1" if s.get("knownIssue") else "0")
print(json.dumps({"sql": s.get("setupSQL", {}), "files": s.get("files", {})}))
for a in s.get("args", []): print(a)
PY
)}")
  requires="${meta[1]}"; fixture="${meta[2]}"; known="${meta[3]}"; setup="${meta[4]}"; args=("${(@)meta[5,-1]}")
  missing=""
  for need in ${=requires}; do
    case "$need" in
      postgres) nc -z 127.0.0.1 "${UI_TEST_PG_PORT:-55432}" >/dev/null 2>&1 || missing+=" postgres" ;;
      mysql) nc -z 127.0.0.1 "${UI_TEST_MYSQL_PORT:-53306}" >/dev/null 2>&1 || missing+=" mysql" ;;
      mongo) nc -z 127.0.0.1 "${UI_TEST_MONGO_PORT:-57017}" >/dev/null 2>&1 || missing+=" mongo" ;;
      redis) nc -z 127.0.0.1 "${UI_TEST_REDIS_PORT:-56379}" >/dev/null 2>&1 || missing+=" redis" ;;
      mock-ai) ;;
    esac
  done
  if [[ -n "$missing" ]]; then echo "-- $name (skipped: no$missing)"; skipped=$((skipped+1)); continue; fi

  defaults delete "$TEST_ID" >/dev/null 2>&1
  run="$OUT/$name"
  rm -rf "$run"; mkdir -p "$run/data" "$run/shots"
  cp "$ROOT/Resources/Samples/demo.sqlite" "$run/demo.sqlite"
  # A second copy and an empty database, for transfers and sync ({{RUN}}/demo2.sqlite, {{RUN}}/empty.sqlite).
  cp "$ROOT/Resources/Samples/demo.sqlite" "$run/demo2.sqlite"
  : > "$run/empty.sqlite"
  # "setupSQL": {"demo2.sqlite": "UPDATE …"} prepares those copies; "files": {"in.csv": "text"} writes input files.
  /usr/bin/python3 -I -c '
import json, sqlite3, sys
setup = json.loads(sys.argv[2])
for name, sql in setup["sql"].items():
    db = sqlite3.connect(sys.argv[1] + "/" + name); db.executescript(sql); db.commit(); db.close()
for name, text in setup["files"].items():
    import os; os.makedirs(os.path.dirname(sys.argv[1] + "/" + name), exist_ok=True); open(sys.argv[1] + "/" + name, "w").write(text)' "$run" "$setup"
  # A scenario may seed the data dir (connections.json with {{PORT}} placeholders) from scripts/ui-scenarios/fixtures.
  if [[ "$fixture" != "demo" && -d "$SCENARIOS/fixtures/$fixture" ]]; then
    for f in "$SCENARIOS/fixtures/$fixture"/*; do
      sed -e "s|{{PG_PORT}}|${UI_TEST_PG_PORT:-55432}|g" -e "s|{{MYSQL_PORT}}|${UI_TEST_MYSQL_PORT:-53306}|g" \
          -e "s|{{MONGO_PORT}}|${UI_TEST_MONGO_PORT:-57017}|g" -e "s|{{REDIS_PORT}}|${UI_TEST_REDIS_PORT:-56379}|g" \
          -e "s|{{RUN}}|$run|g" "$f" > "$run/data/${f:t}"
    done
  fi
  # fixtures/NAME/secrets.json ({"<connection id>": "password"}) seeds the in-memory Keychain.
  seed="{}"
  [[ -f "$run/data/secrets.json" ]] && seed="$(cat "$run/data/secrets.json")" && rm "$run/data/secrets.json"
  mock_pid=""
  if [[ " $requires " == *" mock-ai "* ]]; then
    (cd "$run" && exec /usr/bin/python3 -I "$ROOT/scripts/ui-scenarios/mock-ai.py" 58989) > "$run/mock-ai.log" 2>&1 &
    mock_pid=$!
    sleep 0.5
  fi
  # {{DB}} in args is this run's demo.sqlite copy; {{RUN}} its directory.
  final=()
  for a in "${args[@]}"; do a="${a//\{\{DB\}\}/$run/demo.sqlite}"; final+=("${a//\{\{RUN\}\}/$run}"); done
  (
    cd "$run"
    BUNNYGRID_DATA_DIR="$run/data" BUNNYGRID_MEMORY_KEYCHAIN=1 BUNNYGRID_UI_RUN="$run" BUNNYGRID_LAUNCH_AGENTS_DIR="$run/agents" \
    BUNNYGRID_ANTHROPIC_BASE_URL="http://127.0.0.1:58989" BUNNYGRID_OPENAI_BASE_URL="http://127.0.0.1:58989" \
    ANTHROPIC_API_KEY="mock-key" OPENAI_API_KEY="mock-key" BUNNYGRID_MEMORY_KEYCHAIN_SEED="$seed" \
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
    if [[ "$known" == 1 ]]; then echo "XPASS $name (known issue fixed? remove \"knownIssue\")"; else echo "ok $name"; fi
    passed=$((passed+1))
  else
    if [[ -f "$run/timeout" ]]; then reason="timed out"
    elif [[ ! -f "$run/results.json" ]]; then reason="crashed (exit $code), see $run/app.log"
    else reason=$(/usr/bin/python3 -I -c '
import json,sys
r = json.load(open(sys.argv[1]))
bad = [s for s in r["steps"] if not s["ok"] and not s.get("optional")]
b = bad[0] if bad else None
print(r.get("fatal") or ("step %s %s %s: %s" % (b["index"], b["op"], b.get("note") or "", b.get("error")) if b else "failed"))' "$run/results.json")
    fi
    if [[ "$known" == 1 ]]; then
      echo "xfail $name (known issue): $reason"
      xfailed=$((xfailed+1))
    else
      echo "FAIL $name: $reason"
      failed=$((failed+1)); FAILED+=("$name")
    fi
  fi
done
echo "$passed passed, $failed failed, $xfailed known issues, $skipped skipped  (results in $OUT)"
(( failed == 0 ))
