// Building what the extension sends to the app.
(function (root) {
  function cookieHeader(cookies) {
    return (cookies || []).map((c) => `${c.name}=${c.value}`).join('; ');
  }

  function buildDownloadBody({ url, filename, referrer, cookies, userAgent, pageTitle, kind, audioUrl, videoId }) {
    const body = { url };
    if (audioUrl) body.audioUrl = audioUrl;
    if (videoId) body.videoId = String(videoId);
    if (filename) body.filename = filename;
    if (referrer) body.referrer = referrer;
    if (cookies) body.cookies = cookies;
    if (userAgent) body.userAgent = userAgent;
    if (pageTitle) body.pageTitle = pageTitle;
    if (kind) body.kind = kind;
    return body;
  }

  function isHTTP(url) {
    try { const u = new URL(url); return u.protocol === 'http:' || u.protocol === 'https:'; } catch { return false; }
  }

  const api = { cookieHeader, buildDownloadBody, isHTTP };
  root.HaulRequest = api;
  if (typeof module !== 'undefined') module.exports = api;
})(globalThis);
