#!/usr/bin/env bash
# Builds a Debug Haul and installs it into /Applications for day-to-day testing, then launches it.
#   ./scripts/install-local.sh [--direct]
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(./scripts/build.sh Debug "$@" | tail -1)
osascript -e 'quit app "Haul"' >/dev/null 2>&1 || true
rm -rf /Applications/Haul.app
cp -R "$app" /Applications/Haul.app
open /Applications/Haul.app
echo "/Applications/Haul.app"
