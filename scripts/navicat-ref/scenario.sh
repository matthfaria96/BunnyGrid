#!/bin/zsh
# Usage: scenario.sh <name> <window-id> '<steps json>'   — runs a REA AX scenario on Navicat and extracts PNG + tree.
set -e
HERE="${0:A:h}"
NAME=$1; WID=$2; STEPS=$3
R="${HERE:h:h}/docs/navicat-reference"
PID=$(pgrep -f "Navicat Premium.app/Contents/MacOS/Navicat Premium" | head -1)
cd "/Users/macmini/Documents/VSCode Temp/rea"
node scripts/rea.mjs capture-native-ui-scenario "/Applications/Navicat Premium.app" --pid $PID --window-id $WID --max-nodes 2000 --steps "$STEPS" --format json --full-output > "$R/$NAME.json"
python3 "$HERE/extract.py" "$R/$NAME.json" "$NAME"
