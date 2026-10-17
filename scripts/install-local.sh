#!/usr/bin/env bash
# Builds a Release Komizo and installs it into /Applications, then launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
app=$(./scripts/build.sh Release | tail -1)
pkill -x Komizo >/dev/null 2>&1 || true
sleep 1
rm -rf /Applications/Komizo.app
cp -R "$app" /Applications/Komizo.app
open /Applications/Komizo.app
echo "/Applications/Komizo.app"
