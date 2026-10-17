#!/bin/zsh
# Usage: observe.sh <name> <window-id>   — REA passive capture of one Navicat window into docs/navicat-reference.
set -e
HERE="${0:A:h}"
NAME=$1; WID=$2
R="${HERE:h:h}/docs/navicat-reference"
PID=$(pgrep -f "Navicat Premium.app/Contents/MacOS/Navicat Premium" | head -1)
cd "/Users/macmini/Documents/VSCode Temp/rea"
node scripts/rea.mjs observe-native-ui "/Applications/Navicat Premium.app" --pid $PID --window-id $WID --max-nodes 2000 --format json --full-output > "$R/$NAME.json"
python3 "$HERE/extract.py" "$R/$NAME.json" "$NAME"
