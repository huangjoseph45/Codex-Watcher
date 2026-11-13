#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/build-app.sh

# Launch Services otherwise reuses the existing process, even after a rebuild.
osascript <<'APPLESCRIPT'
repeat 100 times
    if application id "com.codexwatcher.app" is not running then exit repeat
    tell application id "com.codexwatcher.app" to quit
    delay 0.1
end repeat
if application id "com.codexwatcher.app" is running then error "Session Scout did not quit. Close it and try again."
APPLESCRIPT

LOG_PATH="${TMPDIR:-/tmp}/session-scout.log"
open -n --stdout "$LOG_PATH" --stderr "$LOG_PATH" "$PWD/dist/Session Scout.app"
echo "Launched Session Scout. Look for the lookout flag icon in the menu bar."
echo "Startup log: $LOG_PATH"
