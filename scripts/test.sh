#!/usr/bin/env bash
# Runs every check: the identity scan, the core package, the installer, the extension's logic, then the app-hosted tests.
# Silent on success; the exit code is the verdict.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/check-identity.sh
(cd Core && swift test --quiet)
./scripts/test-install.sh
if [[ -d Extension/lib ]]; then (cd Extension && node --test lib/*.test.js >/dev/null); fi
xcodegen generate --quiet
xcodebuild -project Haul.xcodeproj -scheme Haul -configuration Debug -derivedDataPath build/DerivedData \
  -destination 'platform=macOS,arch=arm64' -quiet test
