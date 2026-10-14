#!/usr/bin/env bash
# Runs every check: the identity scan, the core package, the installer, the extension's logic, then the app-hosted tests
# (HAUL_SKIP_HOSTED=1 builds the app instead of running those, for CI runners without a window session).
# Silent on success; the exit code is the verdict.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/check-identity.sh
if [[ "${HAUL_SKIP_HOSTED:-}" == "1" ]]; then
  # On CI, run the suites one at a time and name each first, so a hang in the log points at its culprit.
  (cd Core && swift build --build-tests --quiet)
  for suite in $(grep -hoE "^(struct|final class) [A-Za-z]+Tests\b" Core/Tests/HaulCoreTests/*.swift | awk '{print $NF}' | sort -u); do
    echo "== $suite"
    (cd Core && swift test --skip-build --filter "^$suite/" --quiet)
  done
else
  (cd Core && swift test --quiet)
fi
./scripts/test-install.sh
if [[ -d Extension/lib ]]; then (cd Extension && node --test lib/*.test.js >/dev/null); fi
xcodegen generate --quiet
if [[ "${HAUL_SKIP_HOSTED:-}" == "1" ]]; then
  # A headless CI runner has no window session for the app-hosted tests to run in; build the app instead,
  # so a compile error anywhere still fails the run.
  xcodebuild -project Haul.xcodeproj -scheme Haul -configuration Debug -derivedDataPath build/DerivedData -quiet build
else
  xcodebuild -project Haul.xcodeproj -scheme Haul -configuration Debug -derivedDataPath build/DerivedData \
    -destination 'platform=macOS,arch=arm64' -quiet test
fi
