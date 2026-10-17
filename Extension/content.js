// Catches clicks on links to files while Komizo is connected, so Safari gets downloads too. A plain left click only;
// modifier clicks and the browser's own download flow are left alone.
(function () {
  const api = globalThis.browser ?? globalThis.chrome;
  let connected = false;
  let capture = true;

  api.storage.local.get({ connected: false, capture: true, token: null }).then((s) => {
    connected = !!(s.connected && s.token);
    capture = s.capture !== false;
  });
  api.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local') return;
    api.storage.local.get({ connected: false, capture: true, token: null }).then((s) => {
      connected = !!(s.connected && s.token);
      capture = s.capture !== false;
    });
  });

  // Every <video> on the page, including those inside players' shadow roots (Reddit's, for one).
  function allVideos(root, out = []) {
    for (const el of root.querySelectorAll('*')) {
      if (el.tagName === 'VIDEO') out.push(el);
      if (el.shadowRoot) allVideos(el.shadowRoot, out);
    }
    return out;
  }

  // The videos a person is watching: on screen and started; real videos before looping GIF-style clips (some sites
  // mark those <video loop>), then by the video's own picture size, not the space it fills: a GIF clip is often a
  // small picture stretched over a big box (X's are 244×224 shown at 520×477). Their source names the file when the
  // player plays one directly; a blob: player gives only its length and picture size, which Komizo matches instead.
  function playingVideos() {
    return allVideos(document)
      .map((v) => ({ v, box: v.getBoundingClientRect() }))
      .filter(({ v, box }) => box.width * box.height > 0 && box.bottom > 0 && box.top < innerHeight && box.right > 0 && box.left < innerWidth
        && (!v.paused || v.currentTime > 0) && v.readyState > 0)
      .sort((a, b) => (a.v.loop - b.v.loop) || (b.v.videoWidth * b.v.videoHeight - a.v.videoWidth * a.v.videoHeight)
        || (b.box.width * b.box.height - a.box.width * a.box.height))
      .map(({ v }) => ({ src: v.currentSrc || v.src || '', duration: Number.isFinite(v.duration) ? v.duration : 0, width: v.videoWidth, height: v.videoHeight }));
  }

  // The popup asks for the page's own video sources, what is playing, and the page's own name for itself.
  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || message.type !== 'scan') return false;
    const media = globalThis.KomizoMedia;
    let found = [];
    if (media && media.findDashSets) {
      const html = document.documentElement.outerHTML;
      // Joinable DASH pairs first (video + audio, this page's video before others), then plain progressive files.
      found = media.findDashSets(html, media.pageVideoId(location.href)).concat(media.findInPage(html));
    }
    const og = document.querySelector('meta[property="og:title"]');
    sendResponse({ items: found, playing: playingVideos(), ogTitle: og ? og.content : null });
    return false;
  });

  document.addEventListener('click', (event) => {
    if (!connected || !capture) return;
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const anchor = event.target && event.target.closest && event.target.closest('a[href]');
    if (!anchor) return;
    const href = anchor.href;
    if (!KomizoLinks.isFileLink(href, anchor.hasAttribute('download'))) return;
    event.preventDefault();
    event.stopPropagation();
    api.runtime.sendMessage({ type: 'download', url: href, referrer: location.href, pageTitle: document.title }).then((result) => {
      if (!result || !result.ok) window.location.href = href;
    }, () => { window.location.href = href; });
  }, true);
})();
