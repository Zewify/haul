// Catches clicks on links to files while Haul is connected, so Safari gets downloads too. A plain left click only;
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

  // The popup asks for the page's own video sources (direct edition); the store edition's stub finds nothing.
  api.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (!message || message.type !== 'scan') return false;
    const found = globalThis.HaulMedia && HaulMedia.findInPage ? HaulMedia.findInPage(document.documentElement.outerHTML) : [];
    sendResponse(found);
    return false;
  });

  document.addEventListener('click', (event) => {
    if (!connected || !capture) return;
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const anchor = event.target && event.target.closest && event.target.closest('a[href]');
    if (!anchor) return;
    const href = anchor.href;
    if (!HaulLinks.isFileLink(href, anchor.hasAttribute('download'))) return;
    event.preventDefault();
    event.stopPropagation();
    api.runtime.sendMessage({ type: 'download', url: href, referrer: location.href, pageTitle: document.title }).then((result) => {
      if (!result || !result.ok) window.location.href = href;
    }, () => { window.location.href = href; });
  }, true);
})();
