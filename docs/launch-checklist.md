# Haul — launch checklist

What is left before Haul can ship. Tick items here rather than tracking them elsewhere.

## Decided

- [x] Free, one build, published from zewify.com the way PortGlimpse is (owner, 2026-10-14): ad hoc signed, installed with a curl command, source available on GitHub. No Pro, no App Store.
- [ ] The name. "Haul" is a working name; check trademarks before the launch is announced anywhere.
- [ ] Whether "ask before starting" stays on by default.

## Distribution

- [ ] A daily update check against the GitHub release feed, as PortGlimpse's `UpdateChecker` does, with the install command shown when a newer release exists.

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
