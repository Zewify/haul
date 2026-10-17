#!/usr/bin/env bash
# Generates the Xcode project and builds Downhaul.app; prints its path.
#   ./scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-Debug}"
xcodegen generate --quiet
xcodebuild -project Downhaul.xcodeproj -scheme Downhaul -configuration "$configuration" \
  -derivedDataPath build/DerivedData -quiet build
echo "build/DerivedData/Build/Products/$configuration/Downhaul.app"
