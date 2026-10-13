# Haul

A Mac download manager in the mould of Internet Download Manager, sold by Zewify: a browser extension hands downloads to the app, which fetches them over several connections, resumes them, and queues them.
Two editions from one codebase: the **store** edition (Mac App Store) and the **direct** edition (zewify.com, Developer ID) which adds the video grabber.
Haul is a working name.
Design: `docs/superpowers/specs/2026-10-13-haul-design.md`. Plan: `docs/superpowers/plans/2026-10-13-haul.md`. Launch work: `docs/launch-checklist.md`.

## Layout

- `Core/` — the `HaulCore` package: the model and library, filenames, the probe, the segment planner, the part file, `DownloadTask`, `DownloadEngine` (the queue), the local `ExtensionServer`, licences, HLS; plus `licensetool`. Foundation, Network and CryptoKit only; no AppKit.
- `App/` — the SwiftUI app: `Model/AppModel.swift` (library, engine, server delegate, catches), `UI/` (main window, rows, segment map, catch panel, settings, Pro, menu bar).
- `Extension/` — the WebExtension shared by Chrome (load unpacked) and Safari (packaged by the `HaulSafari` target): `background.js` (module service worker), `content.js`, popup, options, `lib/` (pure logic, node-tested), `icons/`.
- `SafariExtension/` — the Safari app extension's handler and Info.plist.
- `AppTests/` — app-hosted tests. `scripts/` — build, test, install, icon, screenshots, the Chrome end-to-end.
- `project.yml` — XcodeGen spec. The `.xcodeproj` is generated and gitignored; never edit or commit it.

## Commands

- `./scripts/test.sh` — core package, extension logic (`node --test`), then hosted tests. Silent on success; the exit code is the verdict. Run before every commit.
- `./scripts/build.sh [Debug|Release] [--direct]` — generates the project and builds; prints the app path.
- `./scripts/install-local.sh [--direct]` — Debug build into `/Applications/Haul.app`, then launches it.
- `HAUL_CHROME=<chrome-for-testing> node scripts/e2e-chrome.mjs <page-url> <file-name>` — the Chrome end-to-end against a running Haul (see the script's header).
- `HAUL_CHROME=<chrome-for-testing> node scripts/e2e-media.mjs <page-url> [seconds]` — the grabber end-to-end: opens a page in a throwaway Chrome, prints what the sniffer found, grabs it, and waits for the file. Needs the direct edition with Pro (`-HaulForcePro YES`).
- `swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset Extension/icons` — re-renders the icons.
- `swift scripts/window-shot.swift <dir> <prefix>` — screenshots every Haul window.
- `cd Core && swift run licensetool issue --key ~/.config/zewify/haul-license.key --id <order> --licensee <name>` — issues a direct-edition Pro licence.

## Rules that are not obvious

- **Every free/Pro rule lives in `FeatureGate`** (`Core/.../Model/FeatureGate.swift`): 4/32 connections, 2/8 concurrent, the grabber only in the direct edition.
- **The edition is the `DIRECT_EDITION` compilation condition**, set by the `Debug-Direct` and `Release-Direct` configurations; `Edition.current` reads it. The store edition's Safari extension is stripped of `lib/media.js` and the `webRequest` permission by `scripts/strip-media.sh` at build time, so no video-grabbing code ships to App Review.
- **The extension talks to the app over `127.0.0.1:48512`**, never native messaging. Every write needs an `Origin` with an extension scheme plus the bearer token issued at pairing; `/status` is open. Pairing is an `NSAlert` the user approves once per browser.
- **The engine claims a download's name at `add`** (`Filename.available` plus an empty part file), so two downloads of one name never share a part file. The task re-probes on every start; a changed validator or size restarts from zero, once.
- **Rebalancing** happens in `DownloadTask.fetchLoop`: when a segment finishes, the largest remaining range over 2 MiB is split and its tail given to the idle connection; a worker stops writing at its (possibly shortened) end.
- **The library is saved every second while anything runs** (`AppModel.start`), and at once on every change, so a crash loses at most a second of segment state.
- **Google Chrome 137+ ignores `--load-extension`**; the end-to-end uses Chrome for Testing. Users load the folder unpacked from `chrome://extensions` until the Web Store listing exists.
- **Chrome lists an idle extension worker nowhere**; the e2e finds Haul's id through `chrome://extensions` and talks to the background through the popup page.
- **Safari needs the extension turned on** in Safari → Settings → Extensions; an ad-hoc build needs "Allow unsigned extensions" in the Develop menu, each Safari launch.
- **The grabber sees two kinds of thing.** The sniffer (`webRequest`) records media responses, with chunk parameters (`bytestart`, `byteend`, `range`) stripped so a stream fetched in pieces is one item; the page scan (`HaulMedia.findInPage`, asked through the content script) pulls muxed progressive URLs out of the page's own scripts (Facebook's `browser_native_hd_url`/`sd_url`) and plain `<video>` sources. Sites that split audio and video (DASH) give the sniffer separate silent tracks; only the page scan yields a file with sound, and Haul never muxes. Verified on a public Facebook reel on 2026-10-13: 1280x720 H.264 + AAC via the page scan.
- **DASH sites are joined natively.** `Extension/lib/media.js` `findDashSets` reads the DASH representations Facebook embeds in every page (`all_video_dash_prefetch_representations`, whole-file URLs, the video id inside each URL's `efg` parameter) and offers one "video + audio" item per codec family, H.264 first, the page's own video first; `DashTask` downloads the two tracks as ordinary segmented downloads and `Muxer` joins them with an AVFoundation passthrough export (no re-encoding, no ffmpeg). VP9 is left out because AVFoundation cannot read it; AV1 is offered with a "newer Macs only" note. A finished grab is inspected (`MediaInfo`) and a silent file gets `mediaNote`, shown in its row.
- **Media is named after the page title** (`Filename.mediaName`), because CDN names are hashes; a `Content-Disposition` name still wins.
- **Licences are verified offline** against `LicenseKeys.production`; the private key is `~/.config/zewify/haul-license.key` on the owner's Mac, never in the repo.
- **Debug launch arguments:** `-HaulShow settings|catch`, `-HaulForcePro YES`.
- **A Debug build shares the installed app's sandbox container**, `~/Library/Containers/com.zewify.haul`, and so its `library.json`.
- zsh has a `log` builtin; use `/usr/bin/log stream --predicate 'subsystem == "com.zewify.haul"'`.
- Zewify rule: nothing in the app, repo or site may identify the person who builds it (the Developer ID signature on the direct edition is the accepted exception).
