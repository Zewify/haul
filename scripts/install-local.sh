#!/usr/bin/env bash
# Builds a Release Downhaul and installs it into /Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(./scripts/build.sh Release | tail -1)
pkill -x Downhaul >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Downhaul.app
cp -R "$app" /Applications/Downhaul.app
open /Applications/Downhaul.app
echo "/Applications/Downhaul.app"
