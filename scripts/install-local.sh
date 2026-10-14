#!/usr/bin/env bash
# Builds a Release Haul and installs it into /Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(./scripts/build.sh Release | tail -1)
pkill -x Haul >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Haul.app
cp -R "$app" /Applications/Haul.app
open /Applications/Haul.app
echo "/Applications/Haul.app"
