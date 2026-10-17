#!/usr/bin/env bash
# Builds Release (universal, ad hoc signed) and writes the release assets to build/release/.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' project.yml | head -n 1)
app="$(./scripts/build.sh Release | tail -1)"
archs=$(lipo -archs "$app/Contents/MacOS/Downhaul")
for arch in arm64 x86_64; do echo "$archs" | grep -qw "$arch" || { echo "Not a universal binary: $archs" >&2; exit 1; }; done
out=build/release
rm -rf "$out"; mkdir -p "$out"
zip="Downhaul-$version.zip"
# The zip holds the app and the Chrome extension side by side; the installer puts the extension in a fixed folder
# that Chrome loads unpacked. The extension's tests and package file stay out of it.
stage="$out/stage"
mkdir -p "$stage"
ditto "$app" "$stage/Downhaul.app"
rsync -a --exclude '*.test.js' --exclude 'package.json' Extension/ "$stage/Extension/"
[ -f "$stage/Extension/manifest.json" ] || { echo "The extension did not make it into the release" >&2; exit 1; }
ditto -c -k --sequesterRsrc "$stage" "$out/$zip"
rm -rf "$stage"
(cd "$out" && shasum -a 256 "$zip" > "$zip.sha256")
cat > "$out/notes.md" <<NOTES
Install or update:

\`\`\`
curl -fsSL https://zewify.com/downhaul/install.sh | sh
\`\`\`

Needs macOS 15 or later.
This build is signed ad hoc, so it is meant to be installed with the command above rather than opened from a browser download.
The command also puts the Chrome extension in \`~/Library/Application Support/Downhaul/Extension\`. Load that folder unpacked from \`chrome://extensions\` (Developer mode, then Load unpacked); Downhaul's Settings, under Browser, copies the path. Safari's extension comes inside the app.
NOTES
if [ -f "docs/releases/$version.md" ]; then
  { printf '\n## What'"'"'s new\n\n'; cat "docs/releases/$version.md"; } >> "$out/notes.md"
fi
echo "$out/$zip"
