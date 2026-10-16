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
- [x] Grabber: any site's HLS and DASH, not just Facebook (2026-10-17). HLS with separate audio is joined, any MPD is read, protected and live streams are refused in a sentence, the popup lists the stream instead of its pieces and ads. End-to-end round with `scripts/e2e-media.mjs`, each file opened with AVFoundation:
  - TED (HLS, audio apart): 19 min 640x480 H.264 + AAC; it was silent before.
  - dash.js reference (Akamai MPD, `$Number$` template): 10.5 min 3840x2160 H.264 + AAC, 939 MB; it was one unplayable fragment before.
  - hls.js demo (muxed HLS): 1080p with sound. Internet Archive (MP4) and w3schools (`<video>`): whole files with sound.
  - Vimeo: refused, "This video is protected (DRM) and cannot be saved." Its manifests carry CENC with Widevine and PlayReady.
- [ ] Grabber: Reddit, X and Instagram are untested (Reddit refuses a plain fetch, so it needs a signed-in browser run). Vimeo shows its two manifests (720p cap and full) as two identical rows.
- [ ] Grabber: the catch panel for media should show which item is which (HD with audio, SD, stream) and let the user pick; today the popup shows the list and the panel shows one.
- [ ] Grabber: Facebook names. The page title is "Facebook" when signed in, so files are "Facebook <video id>.mp4"; the caption is only in the crawler-served page. Decide whether to fetch the caption (one more page load as a crawler) or let the user rename in the panel.
- [ ] Grabber: YouTube is out of scope. Its streams are DASH with signed, throttled, frequently re-encrypted URLs that need a maintained extractor (yt-dlp carries thousands of lines for it), its terms forbid it, and Apple rejects it; say so in the popup instead of showing silent tracks.
- [ ] Notifications when a download finishes.
- [ ] Website pages in the `zewify` repo (`/haul/`), with screenshots from `scripts/window-shot.swift`.
- [ ] The menu bar ring: check it against light and dark menu bars at 2560 wide.
