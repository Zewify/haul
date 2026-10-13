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

  // The video a page is about, from its URL: /reel/<id>, /watch/?v=<id>, /videos/<id>/.
  function pageVideoId(href) {
    let u;
    try { u = new URL(href); } catch { return null; }
    const v = u.searchParams.get('v');
    if (v && /^\d+$/.test(v)) return v;
    const m = /\/(?:reel|reels|videos)\/(\d+)/.exec(u.pathname);
    return m ? m[1] : null;
  }

  // Facebook embeds every DASH representation of every video on the page, as whole-file URLs, in
  // "all_video_dash_prefetch_representations". Each URL's efg parameter is base64 JSON naming the video and its length.
  function decodeEfg(url) {
    try {
      const raw = new URL(url).searchParams.get('efg') || '';
      const text = atob(raw.replace(/=+$/, '').replace(/-/g, '+').replace(/_/g, '/'));
      // Read the id as text: Facebook ids exceed JavaScript's safe integer range, and JSON.parse would round them.
      const id = /"video_id":\s*"?(\d+)"?/.exec(text);
      const duration = /"duration_s":\s*"?(\d+(?:\.\d+)?)"?/.exec(text);
      return { videoId: id ? id[1] : null, duration: duration ? Number(duration[1]) : undefined };
    } catch { return { videoId: null }; }
  }
  function balancedArray(text, start) {
    let depth = 0, inString = false, escaped = false;
    for (let i = start; i < text.length; i++) {
      const c = text[i];
      if (inString) { if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') inString = false; continue; }
      if (c === '"') inString = true;
      else if (c === '[') depth++;
      else if (c === ']') { depth--; if (depth === 0) return text.slice(start, i + 1); }
    }
    return null;
  }
  // H.264 plays everywhere; AV1 only on recent hardware. Each family gets its own item, H.264 first.
  function codecFamily(codecs) {
    const c = (codecs || '').toLowerCase();
    if (c.startsWith('avc1') || c.startsWith('avc3')) return { name: 'H.264', rank: 3, note: '' };
    if (c.startsWith('hvc1') || c.startsWith('hev1')) return { name: 'HEVC', rank: 2, note: '' };
    if (c.startsWith('av01')) return { name: 'AV1', rank: 1, note: ' · plays on newer Macs only' };
    return null;   // VP9 and the rest cannot be joined into an MP4 on a Mac
  }
  function findDashSets(html, currentVideoId) {
    const key = '"all_video_dash_prefetch_representations":';
    const byVideo = new Map();
    let from = 0;
    while (true) {
      const at = html.indexOf(key, from);
      if (at < 0) break;
      from = at + key.length;
      const raw = balancedArray(html, from);
      if (!raw) continue;
      let sets;
      try { sets = JSON.parse(raw); } catch { continue; }
      for (const set of sets) {
        for (const rep of set.representations || []) {
          if (!rep.base_url || !rep.mime_type) continue;
          const url = String(rep.base_url).replace(/\\\//g, '/').replace(/\\u0025/gi, '%');
          const { videoId, duration } = decodeEfg(url);
          if (!videoId) continue;
          const entry = byVideo.get(videoId) || { video: [], audio: [], duration };
          (rep.mime_type.startsWith('audio/') ? entry.audio : entry.video).push({ url, codecs: rep.codecs, width: rep.width, height: rep.height, bandwidth: rep.bandwidth });
          byVideo.set(videoId, entry);
        }
      }
    }
    const items = [];
    for (const [videoId, entry] of byVideo) {
      if (!entry.video.length || !entry.audio.length) continue;
      const audio = entry.audio.slice().sort((a, b) => b.bandwidth - a.bandwidth)[0];
      const own = videoId === currentVideoId;
      const families = new Map();
      for (const v of entry.video) {
        const family = codecFamily(v.codecs);
        if (!family) continue;
        const best = families.get(family.name);
        if (!best || v.height > best.height || (v.height === best.height && v.bandwidth > best.bandwidth)) families.set(family.name, { ...v, family });
      }
      for (const v of [...families.values()].sort((a, b) => b.family.rank - a.family.rank)) {
        items.push({ kind: 'dash', videoId, url: v.url, audioUrl: audio.url,
          label: `${own ? 'This video' : 'Another video on this page'} · ${v.height}p ${v.family.name} · video + audio${v.family.note}`,
          duration: entry.duration, width: v.width, height: v.height, codec: v.family.name });
      }
    }
    items.sort((a, b) => (b.videoId === currentVideoId) - (a.videoId === currentVideoId));
    return items;
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
    if (item.label) title = item.label + (item.duration ? ` · ${Math.floor(item.duration / 60)}:${String(Math.round(item.duration % 60)).padStart(2, '0')}` : '');
    else if (item.kind === 'hls') title = 'Stream (HLS)';
    else if (type.startsWith('audio/')) title = `Audio (${format})`;
    else title = format ? `Video (${format})` : 'Video';
    if (!item.label && item.size) title += ` · ${formatSize(item.size)}`;
    return { title, subtitle: [host, name].filter(Boolean).join(' · ') };
  }

  const api = { classifyResponse, describeMedia, formatSize, normaliseMediaURL, findInPage, findDashSets, pageVideoId };
  root.HaulMedia = api;
  if (typeof module !== 'undefined') module.exports = api;
})(globalThis);
