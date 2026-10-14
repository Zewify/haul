#!/usr/bin/env bash
# A public repo must not name the person who builds it. Scans the tracked files against the owner's denylist
# when it is present on this Mac (~/.config/zewify/identity-denylist, one regex per line); elsewhere it is a no-op.
set -euo pipefail
cd "$(dirname "$0")/.."
list="$HOME/.config/zewify/identity-denylist"
[ -f "$list" ] || exit 0
if git ls-files -z | xargs -0 grep -IinE -f <(grep -v '^#' "$list") -- 2>/dev/null | head -n 20 | grep .; then
  echo "Identity strings found in tracked files (see above)." >&2
  exit 1
fi
