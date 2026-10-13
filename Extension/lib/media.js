// How a network response is recognised as a video or stream worth grabbing (direct edition only).
(function (root) {
  const HLS_TYPES = ['application/vnd.apple.mpegurl', 'application/x-mpegurl', 'audio/mpegurl', 'audio/x-mpegurl'];
  const SEGMENT_EXTENSIONS = new Set(['ts', 'm4s', 'aac', 'vtt']);
  const SEGMENT_TYPES = ['video/mp2t', 'video/iso.segment'];
  const FILE_EXTENSIONS = new Set(['mp4', 'm4v', 'webm', 'mov', 'mkv', 'm4a', 'mp3', 'flac', 'wav', 'ogg', 'opus']);

  function extensionOf(url) {
    let path;
    try { path = new URL(url).pathname; } catch { return ''; }
    const last = path.slice(path.lastIndexOf('/') + 1);
    const dot = last.lastIndexOf('.');
    return dot < 0 ? '' : last.slice(dot + 1).toLowerCase();
  }

  // 'hls' | 'file' | null
  function classifyResponse(url, contentType) {
    const type = (contentType || '').split(';')[0].trim().toLowerCase();
    const ext = extensionOf(url);
    if (ext === 'm3u8' || HLS_TYPES.includes(type)) return 'hls';
    if (SEGMENT_EXTENSIONS.has(ext) || SEGMENT_TYPES.includes(type)) return null;
    if (type.startsWith('video/') || type.startsWith('audio/')) return 'file';
    if (FILE_EXTENSIONS.has(ext)) return 'file';
    return null;
  }

  // Facebook and others fetch one file in chunks through query parameters; without them the URL is the whole file.
  const CHUNK_PARAMS = ['bytestart', 'byteend', 'range'];
  function normaliseMediaURL(url) {
    let u;
    try { u = new URL(url); } catch { return url; }
    let changed = false;
    for (const key of CHUNK_PARAMS) if (u.searchParams.has(key)) { u.searchParams.delete(key); changed = true; }
    return changed ? u.toString() : url;
  }

  // Muxed progressive files that a page's own scripts know about (Facebook's HD/SD urls), plus plain <video> sources.
  const PAGE_PATTERNS = [
    { re: /"browser_native_hd_url":"((?:https?:)?(?:\\\/|\/)[^"]+)"/g, label: 'HD (video + audio)' },
    { re: /"browser_native_sd_url":"((?:https?:)?(?:\\\/|\/)[^"]+)"/g, label: 'SD (video + audio)' },
    { re: /<(?:video|source)[^>]+src="(https?:[^"]+\.(?:mp4|webm|m4v|mov)(?:\?[^"]*)?)"/g, label: 'Video on page' },
  ];
  function unescapeJSON(text) {
    return text.replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16))).replace(/\\\//g, '/');
  }
  function findInPage(html) {
    const found = [];
    const seen = new Set();
    for (const { re, label } of PAGE_PATTERNS) {
      re.lastIndex = 0;
      let match;
      while ((match = re.exec(html))) {
        const url = unescapeJSON(match[1]);
        if (!/^https?:/.test(url) || seen.has(url)) continue;
        seen.add(url);
        found.push({ url, kind: 'file', label });
      }
    }
    return found;
  }

  function formatSize(bytes) {
    if (!bytes) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    let value = bytes, unit = 0;
    while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit += 1; }
    return `${unit === 0 ? value : value.toFixed(1)} ${units[unit]}`;
  }

  // What the item is (first line) and where it came from (second line), because CDN filenames are hashes.
  function describeMedia(item) {
    let host = '', name = '';
    try {
      const u = new URL(item.url);
      host = u.host;
      name = decodeURIComponent(u.pathname.slice(u.pathname.lastIndexOf('/') + 1));
    } catch { name = item.url; }
    const type = (item.contentType || '').split(';')[0].trim().toLowerCase();
    const format = type.split('/')[1] || extensionOf(item.url);
    let title;
    if (item.label) title = item.label;
    else if (item.kind === 'hls') title = 'Stream (HLS)';
    else if (type.startsWith('audio/')) title = `Audio (${format})`;
    else title = format ? `Video (${format})` : 'Video';
    if (!item.label && item.size) title += ` · ${formatSize(item.size)}`;
    return { title, subtitle: [host, name].filter(Boolean).join(' · ') };
  }

  const api = { classifyResponse, describeMedia, formatSize, normaliseMediaURL, findInPage };
  root.HaulMedia = api;
  if (typeof module !== 'undefined') module.exports = api;
})(globalThis);
