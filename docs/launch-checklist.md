# Haul — launch checklist

What is left before Haul can ship. Tick items here rather than tracking them elsewhere.

## Decisions for the owner

- [ ] The name. "Haul" is a working name; check the Mac App Store and trademarks before anything public uses it.
- [ ] Pro price. Suggested one-time USD 9.99 (IDM charges about USD 25; TickThock Pro is USD 3.99). The app prints no price.
- [ ] The free limits (4 connections, 2 at a time) and Pro limits (32, 8) in `FeatureGate`.
- [ ] Whether "ask before starting" stays on by default.

## Store edition

- [ ] StoreKit: create the Pro product in App Store Connect and wire `ProView` the way TickThock's `StoreService` does.
- [ ] Bundle ID `com.zewify.haul` and the Safari extension `com.zewify.haul.safari` in the developer account; team `GHVX6RBQ64`.
- [ ] `scripts/release.sh` (archive, export, the ITMS-90284 check) modelled on TickThock's.
- [ ] App Review notes: explain the local server (loopback only) and the sandbox entitlements (downloads folder, user-selected folders, network server).
- [ ] Exclude the 27 EU storefronts (the account is not a trader).

## Direct edition

- [ ] Developer ID certificates, signing and notarization; a `.dmg` or `.pkg` via `scripts/package.sh` modelled on VoxMorph's.
- [ ] Licence sales: Paddle or Lemon Squeezy issuing `HAUL1-` keys with `licensetool`.
- [ ] Sparkle or a simple update check, since there is no store to update from.

## Extensions

- [ ] Chrome Web Store developer account, listing, screenshots, privacy disclosure for `<all_urls>` and `cookies` (needed to download files behind logins).
- [ ] Safari: test the packaged extension in a signed build; confirm the content-script capture and context menus; the store edition ships without the sniffer (`scripts/strip-media.sh`).
- [ ] Firefox, if asked for.

## Product

- [ ] Speed limiter and scheduler (Pro, after 1.0).
- [x] Grabber: DASH tracks are joined natively (AVFoundation passthrough); verified on a Facebook reel 2026-10-14. VP9-only videos cannot be joined and are not offered.
- [ ] Grabber: the catch panel for media should show which item is which (HD with audio, SD, stream) and let the user pick; today the popup shows the list and the panel shows one.
- [ ] Grabber: Facebook names. The page title is "Facebook" when signed in, so files are "Facebook <video id>.mp4"; the caption is only in the crawler-served page. Decide whether to fetch the caption (one more page load as a crawler) or let the user rename in the panel.
- [ ] Grabber: YouTube is out of scope. Its streams are DASH with signed, throttled, frequently re-encrypted URLs that need a maintained extractor (yt-dlp carries thousands of lines for it), its terms forbid it, and Apple rejects it; say so in the popup instead of showing silent tracks.
- [ ] Notifications when a download finishes.
- [ ] Website pages in the `zewify` repo (`/haul/`), with screenshots from `scripts/window-shot.swift`.
- [ ] The menu bar ring: check it against light and dark menu bars at 2560 wide.
