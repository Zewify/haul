# Downhaul — launch checklist

What is left before Downhaul can ship. Tick items here rather than tracking them elsewhere.

## Decided

- [x] Free, one build, published from zewify.com the way PortGlimpse is (owner, 2026-10-14): ad hoc signed, installed with a curl command, source available on GitHub. No Pro, no App Store.
- [x] The name (2026-10-17): Downhaul, chosen by the owner after a desk search found another free Mac download manager called Haul (github.com/sibiraj-s/haul, from 2026-10-01) and no app or project called Downhaul, and Zewify/downhaul free. No lawyer's clearance search (owner, 2026-10-17): Downhaul is free and not promoted, so the realistic worst case is being asked to rename, which the 0.3.0 rename showed takes an afternoon. Revisit if it is ever sold or promoted.
- [ ] Whether "ask before starting" stays on by default.

## Distribution

- [x] A daily update check against the GitHub release feed, as PortGlimpse's `UpdateChecker` does (2026-10-17, from 0.2.0): the menu bar menu names a newer release and copies the install command; Settings → General turns it off.

## Extensions

- [x] No Chrome Web Store (owner, 2026-10-17): the extension is loaded unpacked. From 0.2.1 the release carries it and the install command puts it in `~/Library/Application Support/Downhaul/Extension`, replaced in place by each update; Settings → Browser copies the path.
- [ ] Safari: test the packaged extension (it ships inside the app, ad hoc signed); confirm the content-script capture, the context menus and the video popup.
- [ ] Firefox, if asked for.

## Product

- [x] Speed limit (2026-10-17): one cap for all downloads together, in Settings → Connections and as a menu bar toggle. Measured on a 62 MB Archive.org file at 2 MB/s: 2.03 MB/s overall, no burst at the start.
- [ ] Scheduler: start the queue at a set time, optionally sleep or quit when done.
- [x] Grabber: DASH tracks are joined natively (AVFoundation passthrough); verified on a Facebook reel 2026-10-14. VP9-only videos cannot be joined and are not offered.
- [x] Grabber: any site's HLS and DASH, not just Facebook (2026-10-17). HLS with separate audio is joined, any MPD is read, protected and live streams are refused in a sentence, the popup lists the stream instead of its pieces and ads. End-to-end round with `scripts/e2e-media.mjs`, each file opened with AVFoundation:
  - TED (HLS, audio apart): 19 min 640x480 H.264 + AAC; it was silent before.
  - dash.js reference (Akamai MPD, `$Number$` template): 10.5 min 3840x2160 H.264 + AAC, 939 MB; it was one unplayable fragment before.
  - hls.js demo (muxed HLS): 1080p with sound. Internet Archive (MP4) and w3schools (`<video>`): whole files with sound.
  - Vimeo: refused, "This video is protected (DRM) and cannot be saved." Its manifests carry CENC with Widevine and PlayReady.
- [x] Grabber: popular sites, each grab checked by its file's tracks and a frame against the page (2026-10-17, signed out, Chrome for Testing): Reddit (the post, not the ad beside it), TikTok (the page's video, not a larger feed neighbour), X (the tweet's video, not a GIF clip), Instagram and Bilibili (video and sound joined), Twitch, Vimeo (non-DRM), Facebook. Rumble's live channel is refused as live.
- [ ] Grabber: Dailymotion is unverified. In Chrome for Testing its own player gets 403 on the video and plays only ads, so it needs a run in a real browser. Vimeo shows its two manifests (720p cap and full) as two identical rows.
- [ ] Grabber: signed-in pages (Instagram, Facebook and X feeds) are untested.
- [ ] Grabber: the catch panel for media should show which item is which (HD with audio, SD, stream) and let the user pick; today the popup shows the list and the panel shows one.
- [ ] Grabber: Facebook names. The page title is "Facebook" when signed in, so files are "Facebook <video id>.mp4"; the caption is only in the crawler-served page. Decide whether to fetch the caption (one more page load as a crawler) or let the user rename in the panel.
- [x] Grabber: YouTube is out of scope. Its streams are DASH with signed, throttled, frequently re-encrypted URLs that need a maintained extractor (yt-dlp carries thousands of lines for it). The popup says "Downhaul does not save video from YouTube." instead of listing pieces that would not play (2026-10-17).
- [ ] Notifications when a download finishes.
- [x] Website pages in the `zewify` repo (`/downhaul/`), with screenshots from `scripts/window-shot.swift`; the tested-sites list there and in the app's "?" popover change together.
- [ ] The menu bar icon's progress bar: check it against light and dark menu bars at 2560 wide.
