#!/usr/bin/env bash
# Generates the Xcode project and builds Komizo.app; prints its path.
#   ./scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-Debug}"
xcodegen generate --quiet
xcodebuild -project Komizo.xcodeproj -scheme Komizo -configuration "$configuration" \
  -derivedDataPath build/DerivedData -quiet build
echo "build/DerivedData/Build/Products/$configuration/Komizo.app"
