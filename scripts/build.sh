#!/usr/bin/env bash
# Generates the Xcode project and builds Haul.app; prints its path.
#   ./scripts/build.sh [Debug|Release] [--direct]
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=Debug
scheme=Haul
for arg in "$@"; do
  case "$arg" in
    Debug|Release) configuration=$arg ;;
    --direct) scheme=Haul-Direct ;;
    *) echo "usage: $0 [Debug|Release] [--direct]" >&2; exit 2 ;;
  esac
done
[[ $scheme == Haul-Direct ]] && configuration="$configuration-Direct"
xcodegen generate --quiet
xcodebuild -project Haul.xcodeproj -scheme "$scheme" -configuration "$configuration" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS,arch=arm64' -quiet build
echo "build/DerivedData/Build/Products/$configuration/Haul.app"
