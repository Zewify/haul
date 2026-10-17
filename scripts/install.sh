#!/bin/sh
# Installs or updates Komizo from its latest GitHub release.
#   curl -fsSL https://zewify.com/komizo/install.sh | sh
# Run it again to update. It never uses sudo, and it only replaces the installed app
# once the new one has been downloaded and its SHA-256 checked.
set -eu

API="${KOMIZO_API:-https://api.github.com/repos/zewify/komizo/releases/latest}"
APP="Komizo.app"
# Where the Chrome extension lives. Chrome loads it unpacked from here, so it stays at this path and each update
# replaces it in place; a reload in chrome://extensions then picks up the new version.
EXTENSION_DIR="${KOMIZO_EXTENSION_DIR:-$HOME/Library/Application Support/Komizo/Extension}"
BUNDLE_ID="com.zewify.komizo"

say() { printf 'Komizo: %s\n' "$1"; }
fail() { printf 'Komizo: %s\n' "$1" >&2; exit 1; }

# This user's running Komizo, if any. Tests replace these three after sourcing the file.
is_running() { pgrep -xu "$(id -u)" Komizo >/dev/null 2>&1; }
quit_app() { osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true; }
launch_app() { open "$1"; }

# The folder the running copy was opened from, or nothing.
running_app_dir() {
  ps -xo comm= -u "$(id -u)" 2>/dev/null | sed -n 's|^\(.*\)/Komizo\.app/Contents/MacOS/Komizo$|\1|p' | head -n 1
}

# Where to install. An update goes where the app already is: the running copy's folder when it is
# inside an Applications folder (a build run from Xcode is not), else an existing copy in
# /Applications or ~/Applications. A first install goes to /Applications when this user can write
# to it (admin accounts can, without sudo), otherwise ~/Applications.
install_dir() {
  if [ -n "${KOMIZO_INSTALL_DIR:-}" ]; then echo "$KOMIZO_INSTALL_DIR"; return; fi
  system="${KOMIZO_APPLICATIONS:-/Applications}"
  running=$(running_app_dir)
  case "$running" in
    "$system" | "$system"/* | "$HOME/Applications" | "$HOME/Applications"/*) echo "$running"; return ;;
  esac
  if [ -d "$system/$APP" ]; then echo "$system"; return; fi
  if [ -d "$HOME/Applications/$APP" ]; then echo "$HOME/Applications"; return; fi
  if [ -w "$system" ]; then echo "$system"; else echo "$HOME/Applications"; fi
}

# Asks GitHub for the latest release into $1, and turns every failure into a plain sentence.
fetch_release() {
  code=$(curl -sSL -H "Accept: application/vnd.github+json" -D "$1.headers" -o "$1" -w '%{http_code}' "$API" 2>/dev/null) || code=000
  case "$code" in
    200) return 0 ;;
    000) fail "couldn't reach GitHub. Check your connection and try again." ;;
    403 | 429)
      # Unsigned requests to GitHub's API are limited to 60 an hour per network.
      if grep -qi 'rate limit' "$1" 2>/dev/null; then
        reset=$(tr -d '\r' < "$1.headers" | sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]eset: *\([0-9][0-9]*\).*/\1/p' | tail -n 1)
        if [ -n "$reset" ]; then
          minutes=$(( (reset - $(date +%s) + 59) / 60 ))
          [ "$minutes" -ge 1 ] || minutes=1
          fail "GitHub limits how often one network can check for releases, and that limit has been reached. Try again in about $minutes minute$([ "$minutes" -eq 1 ] || echo s)."
        fi
        fail "GitHub limits how often one network can check for releases, and that limit has been reached. Try again within the hour."
      fi
      fail "GitHub refused the request (HTTP $code). Try again later." ;;
    *) fail "GitHub answered with an error (HTTP $code). Try again later." ;;
  esac
}

main() {
  [ "$(uname -s)" = "Darwin" ] || fail "this installer is for macOS."
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 15 ] || fail "Komizo needs macOS 15 or later."

  tmp=$(mktemp -d)
  # Clean up on every exit, and make Ctrl-C or a kill actually stop the script.
  trap 'rm -rf "$tmp"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  say "finding the latest release"
  fetch_release "$tmp/release.json"
  zip_url=$(grep -o '"browser_download_url": *"[^"]*/Komizo-[^"/]*\.zip"' "$tmp/release.json" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
  sum_url=$(grep -o '"browser_download_url": *"[^"]*/Komizo-[^"/]*\.zip\.sha256"' "$tmp/release.json" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')
  version=$(grep -o '"tag_name": *"[^"]*"' "$tmp/release.json" | head -n 1 | sed 's/.*"v\{0,1\}\([^"]*\)"$/\1/')
  [ -n "$zip_url" ] && [ -n "$sum_url" ] || fail "the latest release has no download yet. Try again in a few minutes."

  dest=$(install_dir)
  installed=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$dest/$APP/Contents/Info.plist" 2>/dev/null || true)
  if [ -n "$version" ] && [ "$installed" = "$version" ]; then
    say "$version is already installed in $dest, so there is nothing to update."
    retire_old_names
    if [ "${KOMIZO_NO_LAUNCH:-}" != "1" ] && ! is_running; then launch_app "$dest/$APP"; fi
    return 0
  fi

  say "downloading Komizo $version"
  curl -fsSL "$zip_url" -o "$tmp/app.zip" || fail "the download failed. Try again."
  curl -fsSL "$sum_url" -o "$tmp/app.zip.sha256" || fail "the checksum download failed. Try again."
  expected=$(cut -d' ' -f1 "$tmp/app.zip.sha256")
  actual=$(shasum -a 256 "$tmp/app.zip" | cut -d' ' -f1)
  [ "$expected" = "$actual" ] || fail "the download's checksum does not match, so nothing was installed. Try again."

  ditto -x -k "$tmp/app.zip" "$tmp/unpacked" || fail "the download could not be unpacked."
  [ -d "$tmp/unpacked/$APP" ] || fail "the download does not contain $APP."

  mkdir -p "$dest"
  if [ "${KOMIZO_NO_LAUNCH:-}" != "1" ] && is_running; then
    say "quitting Komizo to update it"
    quit_app
    for _ in 1 2 3 4 5 6 7 8 9 10; do is_running || break; sleep 0.5; done
    ! is_running || fail "Komizo didn't quit. Quit it from its panel, then run this again."
  fi
  # Copy the new app in beside the old one, move the old one aside, then move the new one into place.
  # Each step is a rename within one folder, and a failure puts the old copy back, so there is always an app.
  new="$dest/.$APP.new"
  old="$dest/.$APP.old"
  rm -rf "$new" "$old" 2>/dev/null || true
  ditto "$tmp/unpacked/$APP" "$new" || { rm -rf "$new" 2>/dev/null; fail "couldn't write to $dest."; }
  if [ -e "$dest/$APP" ]; then
    mv "$dest/$APP" "$old" || { rm -rf "$new" 2>/dev/null; fail "couldn't move the installed copy aside in $dest, so nothing changed."; }
  fi
  if ! mv "$new" "$dest/$APP"; then
    [ -e "$old" ] && mv "$old" "$dest/$APP"
    fail "couldn't finish installing in $dest; the previous copy is back in place."
  fi
  if [ -e "$old" ]; then
    rm -rf "$old" 2>/dev/null || say "the previous copy couldn't be fully removed; delete $old when you like."
  fi

  say "installed $version in $dest"
  install_extension "$tmp/unpacked/Extension"
  retire_old_names
  if [ "${KOMIZO_NO_LAUNCH:-}" != "1" ]; then
    launch_app "$dest/$APP"
    say "it opens in a window and stays in your menu bar. Run the same command again to update."
  fi
}

# Puts the Chrome extension from the release in EXTENSION_DIR, the same way as the app: new copy beside the old,
# then a rename, so a failure leaves the previous one. A release without it (0.2.0 and earlier) changes nothing.
install_extension() {
  src=$1
  [ -f "$src/manifest.json" ] || return 0
  had=0; [ -e "$EXTENSION_DIR" ] && had=1
  parent=$(dirname "$EXTENSION_DIR")
  mkdir -p "$parent" || { say "couldn't create $parent, so the Chrome extension was not updated."; return 0; }
  enew="$EXTENSION_DIR.new"; eold="$EXTENSION_DIR.old"
  rm -rf "$enew" "$eold" 2>/dev/null || true
  ditto "$src" "$enew" || { rm -rf "$enew" 2>/dev/null; say "couldn't write the Chrome extension to $parent."; return 0; }
  if [ -e "$EXTENSION_DIR" ]; then mv "$EXTENSION_DIR" "$eold" || { rm -rf "$enew"; say "couldn't replace the Chrome extension in $parent."; return 0; }; fi
  if ! mv "$enew" "$EXTENSION_DIR"; then [ -e "$eold" ] && mv "$eold" "$EXTENSION_DIR"; say "couldn't replace the Chrome extension in $parent."; return 0; fi
  rm -rf "$eold" 2>/dev/null || true
  if [ "$had" = 1 ]; then
    say "updated the Chrome extension; press the reload arrow on Komizo's card in chrome://extensions to use it."
  else
    say "the Chrome extension is in: $EXTENSION_DIR"
    say "to add it, open chrome://extensions, turn on Developer mode, click Load unpacked, press Command-Shift-G, paste that path and choose the folder."
  fi
}

# The app was called Haul until 0.2.1 (com.zewify.haul) and Downhaul in 0.3.0 (com.zewify.downhaul). A copy under an
# old name is quit and removed, and so is its Chrome extension folder; Chrome then shows that extension as missing,
# and Komizo's has to be added in its place.
OLD_APP_DIRS="${KOMIZO_OLD_APP_DIRS:-${KOMIZO_APPLICATIONS:-/Applications} $HOME/Applications}"
OLD_SUPPORT_DIR="${KOMIZO_OLD_SUPPORT_DIR:-$HOME/Library/Application Support}"
retire_old_names() {
  retire_old Haul com.zewify.haul
  retire_old Downhaul com.zewify.downhaul
}
retire_old() { # name bundle-id
  name=$1; bundle=$2; extension="$OLD_SUPPORT_DIR/$name/Extension"
  found=0
  for dir in $OLD_APP_DIRS; do [ -d "$dir/$name.app" ] && found=1; done
  [ -d "$extension" ] && found=1
  [ "$found" = 1 ] || return 0
  if [ "${KOMIZO_NO_LAUNCH:-}" != "1" ] && pgrep -xu "$(id -u)" "$name" >/dev/null 2>&1; then
    osascript -e "quit app id \"$bundle\"" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xu "$(id -u)" "$name" >/dev/null 2>&1 || break; sleep 0.5; done
  fi
  for dir in $OLD_APP_DIRS; do
    if [ -d "$dir/$name.app" ]; then
      rm -rf "$dir/$name.app" 2>/dev/null && say "removed $name.app from $dir: $name is now called Komizo." || say "couldn't remove the old $dir/$name.app; delete it when you like."
    fi
  done
  if [ -d "$extension" ]; then
    rm -rf "$extension" 2>/dev/null
    rmdir "$OLD_SUPPORT_DIR/$name" 2>/dev/null || true
    say "in chrome://extensions, remove the old $name extension and add Komizo's folder (above) the same way."
  fi
}

# Tests source this file (KOMIZO_SOURCE_ONLY=1) to call its functions, so main does not run.
if [ "${KOMIZO_SOURCE_ONLY:-}" = "1" ]; then return 0; fi
main "$@"
