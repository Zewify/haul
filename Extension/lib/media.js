// How a network response is recognised as a video or stream worth grabbing (direct edition only).
(function (root) {
  const HLS_TYPES = ['application/vnd.apple.mpegurl', 'application/x-mpegurl', 'audio/mpegurl', 'audio/x-mpegurl'];
  const DASH_TYPES = ['application/dash+xml'];
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

  // The whole length behind a Content-Range ("bytes 0-999/123456"), when the server says it.
  function rangeTotal(contentRange) {
    const m = /\/(\d+)\s*$/.exec(contentRange || '');
    return m ? Number(m[1]) : undefined;
  }

  // A track fetched in pieces is a whole file, not a stream segment, once its total is known and real (Bilibili's .m4s).
  const WHOLE_TRACK_MIN = 1 << 20;

  // 'hls' | 'mpd' | 'file' | null. `response` is { status, range } (its Content-Range), when known.
  function classifyResponse(url, contentType, response = {}) {
    if (response.status >= 400) return null;   // a refused request is not something to offer
    const type = (contentType || '').split(';')[0].trim().toLowerCase();
    const ext = extensionOf(url);
    if (ext === 'm3u8' || HLS_TYPES.includes(type)) return 'hls';
    if (ext === 'mpd' || DASH_TYPES.includes(type)) return 'mpd';
    if (ext === 'm4s' && (rangeTotal(response.range) || 0) >= WHOLE_TRACK_MIN) return 'file';
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
    return itemsFor(byVideo, currentVideoId);
  }

  // One joinable item per codec family per video, H.264 first, the loudest audio, the page's own video first.
  function itemsFor(byVideo, currentVideoId) {
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
        items.push({ kind: 'dash', videoId, url: v.url, audioUrl: audio.url, codecs: v.codecs,
          label: `${own ? 'This video' : 'Another video on this page'} · ${v.height}p ${v.family.name} · video + audio${v.family.note}`,
          duration: entry.duration, width: v.width, height: v.height, codec: v.family.name });
      }
    }
    items.sort((a, b) => (b.videoId === currentVideoId) - (a.videoId === currentVideoId));
    return items;
  }

  // Which video the user means: the url's id when the page offers that video; otherwise whichever video the player
  // is fetching right now (a feed preloads neighbours, so this is only a fallback). With neither, nothing is "another".
  function labelDashItems(items, sniffedUrls, currentVideoId) {
    const sniffed = new Set((sniffedUrls || []).map(normaliseMediaURL));
    const playing = new Set(items.filter((i) => sniffed.has(normaliseMediaURL(i.url)) || sniffed.has(normaliseMediaURL(i.audioUrl || ''))).map((i) => i.videoId));
    const byUrl = currentVideoId && items.some((i) => i.videoId === currentVideoId) ? new Set([currentVideoId]) : null;
    const current = byUrl || (playing.size ? playing : null);
    const labelled = items.map((i) => {
      const own = current ? current.has(i.videoId) : null;
      const who = own === null ? 'Video on this page' : own ? 'This video' : 'Another video on this page';
      const family = codecFamily(i.codecs) || { name: i.codec || 'video', note: i.codec === 'AV1' ? ' · plays on newer Macs only' : '' };
      return { ...i, own: !!own, label: `${who} · ${i.height}p ${family.name} · video + audio${family.note}` };
    });
    labelled.sort((a, b) => (b.own - a.own) || (b.videoId === a.videoId ? 0 : 0));
    return labelled;
  }

  // On a Facebook video page the surest grab is to let Haul read the page itself as Safari would: Facebook then
  // offers a progressive H.264 file, while Chrome is served VP9 or AV1 tracks a Mac may not play.
  function pageReaderItem(tabUrl) {
    let host;
    try { host = new URL(tabUrl).host.toLowerCase(); } catch { return null; }
    if (!(host === 'facebook.com' || host.endsWith('.facebook.com'))) return null;
    const videoId = pageVideoId(tabUrl);
    if (!videoId) return null;
    return { kind: 'page', url: tabUrl, videoId, label: 'This video · 720p H.264 · Haul reads the page' };
  }

  // A DASH manifest (Facebook's dash_mpd_debug.mpd?v=<id>, fetched with the user's session) for one video.
  function parseMPD(xml, videoId) {
    if (!/<MPD[\s>]/.test(xml)) return [];
    const unescape = (t) => t.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
    const attrs = (tag) => Object.fromEntries([...tag.matchAll(/(\w+)="([^"]*)"/g)].map((m) => [m[1], m[2]]));
    const durationMatch = /mediaPresentationDuration="PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?"/.exec(xml);
    const duration = durationMatch ? (Number(durationMatch[1] || 0) * 3600 + Number(durationMatch[2] || 0) * 60 + Number(durationMatch[3] || 0)) : undefined;
    const entry = { video: [], audio: [], duration };
    for (const set of xml.matchAll(/<AdaptationSet([^>]*)>([\s\S]*?)<\/AdaptationSet>/g)) {
      const setMime = attrs(set[1]).mimeType || '';
      for (const rep of set[2].matchAll(/<Representation([^>]*)>([\s\S]*?)<\/Representation>/g)) {
        const a = attrs(rep[1]);
        const base = /<BaseURL>([^<]+)<\/BaseURL>/.exec(rep[2]);
        if (!base) continue;
        const mime = a.mimeType || setMime;
        const item = { url: unescape(base[1].trim()), codecs: a.codecs, width: Number(a.width || 0), height: Number(a.height || 0), bandwidth: Number(a.bandwidth || 0) };
        (mime.startsWith('audio/') ? entry.audio : entry.video).push(item);
      }
    }
    return itemsFor(new Map([[videoId, entry]]), videoId);
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
    if ((item.kind === 'dash' || item.kind === 'page') && item.videoId) name = `video ${item.videoId}`;
    const shape = [item.width && item.height ? `${item.width}×${item.height}` : '', item.duration ? clock(item.duration) : ''].filter(Boolean).join(' · ');
    const type = (item.contentType || '').split(';')[0].trim().toLowerCase();
    const format = type.split('/')[1] || extensionOf(item.url);
    let title;
    if (item.label) title = item.label + (item.duration && !item.shaped ? ` · ${clock(item.duration)}` : '');
    else if (item.live) title = 'Live stream · cannot be saved';
    else if (item.error) title = `${item.kind === 'file' ? 'Video' : 'Stream'} · Haul cannot open this link`;
    else if (item.kind === 'hls') title = 'Stream (HLS)' + (shape ? ` · ${shape}` : '');
    else if (item.kind === 'mpd') title = 'Stream (DASH)' + (shape ? ` · ${shape}` : '');
    else if (item.video === false && item.audio) title = `Audio (${format || 'mp4'})` + (shape ? ` · ${shape}` : '');
    else if (type.startsWith('audio/') && item.video !== true) title = `Audio (${format})`;
    else title = (format ? `Video (${format})` : 'Video') + (item.video && item.audio === false ? ' · no sound' : '') + (shape ? ` · ${shape}` : '');
    // A playlist's own size says nothing about the video it describes.
    if (!item.label && item.size && item.kind === 'file') title += ` · ${formatSize(item.size)}`;
    return { title, subtitle: [host, name].filter(Boolean).join(' · ') };
  }

  // The playlists a master playlist points at (its variants and separate audio), so the popup lists the master alone.
  function hlsChildren(text, base) {
    const lines = String(text || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    if (!lines[0] || !lines[0].startsWith('#EXTM3U')) return [];
    const resolve = (uri) => { try { return normaliseMediaURL(new URL(uri, base).toString()); } catch { return null; } };
    const children = [];
    let variantNext = false;
    for (const line of lines) {
      if (line.startsWith('#EXT-X-STREAM-INF:')) { variantNext = true; continue; }
      const uri = /^#EXT-X-(?:MEDIA|I-FRAME-STREAM-INF):.*\bURI="([^"]+)"/.exec(line);
      if (uri) { const url = resolve(uri[1]); if (url) children.push(url); continue; }
      if (line.startsWith('#')) continue;
      if (variantNext) { const url = resolve(line); if (url) children.push(url); variantNext = false; }
    }
    return children;
  }

  // Video ads play through a page's own player and show up beside the real stream; these networks never carry it.
  const AD_HOSTS = ['doubleclick.net', '2mdn.net', 'googlesyndication.com', 'googleadservices.com', 'imasdk.googleapis.com', 'innity.net',
    'adnxs.com', 'amazon-adsystem.com', 'springserve.com', 'spotxchange.com', 'teads.tv', 'moatads.com', 'serving-sys.com', 'adsrvr.org',
    'pubmatic.com', 'rubiconproject.com', 'smartadserver.com', 'criteo.com', 'taboola.com', 'outbrain.com', 'yieldmo.com', 'flashtalking.com',
    'viously.com'];
  function hostOf(url) { try { return new URL(url).host.toLowerCase(); } catch { return ''; } }
  function isAdHost(url) {
    const host = hostOf(url);
    return AD_HOSTS.some((ad) => host === ad || host.endsWith('.' + ad));
  }

  // What the popup lists of what the sniffer saw: no ads; when a page streams, the stream and not its pieces
  // (segments on the stream's own host, the variant playlists of a master).
  function tidyMedia(items) {
    const kept = (items || []).filter((i) => !isAdHost(i.url));
    const streams = kept.filter((i) => i.kind === 'hls' || i.kind === 'mpd');
    if (!streams.length) return kept;
    const streamHosts = new Set(streams.map((i) => hostOf(i.url)));
    const children = new Set(streams.flatMap((i) => i.children || []));
    return kept.filter((i) => {
      if (i.kind === 'file') return !streamHosts.has(hostOf(i.url));
      if (i.kind === 'hls') return !children.has(i.url);
      return true;
    });
  }

  // Adds a sniffed item, keeping at most `cap`: a busy player fetches hundreds of pieces, and they must never push
  // the stream itself out, so the oldest plain file goes first.
  function recordMedia(list, item, cap = 30) {
    if (list.some((i) => i.url === item.url)) return false;
    list.push(item);
    while (list.length > cap) {
      const index = list.findIndex((i) => i.kind === 'file');
      list.splice(index < 0 ? 0 : index, 1);
    }
    return true;
  }

  function clock(seconds) {
    const s = Math.round(seconds);
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = String(s % 60).padStart(2, '0');
    return h ? `${h}:${String(m).padStart(2, '0')}:${r}` : `${m}:${r}`;
  }

  // The tab's title, unless it is only the site's name ("X", "Instagram"): then the page's own og:title says more.
  function bestTitle(tabTitle, ogTitle) {
    const tab = (tabTitle || '').trim(), og = (ogTitle || '').trim();
    const bare = !/\s/.test(tab.replace(/\s*[-|·]\s*[^-|·]+$/, '').trim());
    return bare && og.length > tab.length ? og : tab || og;
  }

  // Lengths agree when within a second, or 3% for long videos: players round, and trims differ slightly.
  function sameLength(a, b) {
    return a > 0 && b > 0 && Math.abs(a - b) <= Math.max(1, 0.03 * Math.max(a, b));
  }

  // Which item is the video being watched: the one a visible playing <video> plays, by its source when it names one,
  // else (a blob: player) by length, then by picture size. `playing` is what the content script reports, best first.
  function markPlaying(items, playing) {
    const watched = (playing || [])[0];
    if (!watched) return items;
    const bySource = watched.src && !watched.src.startsWith('blob:') ? normaliseMediaURL(watched.src) : null;
    let match = bySource ? items.find((i) => normaliseMediaURL(i.url) === bySource) : null;
    if (!match && watched.duration) {
      const candidates = items.filter((i) => !i.live && i.video !== false && sameLength(i.duration, watched.duration));
      // A pair with sound beats its silent half; the same picture size beats another.
      const sameSize = (i) => i.width === watched.width && i.height === watched.height;
      candidates.sort((a, b) => ((b.kind === 'dash') - (a.kind === 'dash')) || (sameSize(b) - sameSize(a)) || ((b.size || 0) - (a.size || 0)));
      match = candidates[0];
    }
    if (!match) return items;
    // A silent file that is the playing one hands "playing" to the pair that carries its sound.
    const pair = match.kind === 'file' ? items.find((i) => i.kind === 'dash' && i.url === match.url) : null;
    const chosen = pair || match;
    return [{ ...chosen, playing: true }].concat(items.filter((i) => i !== chosen));
  }

  // A video-only file and an audio-only file of the same length are one video whose sound comes apart (Instagram,
  // Bilibili, any DASH site serving whole tracks): offered joined, ahead of its halves.
  function pairTracks(items) {
    const silent = items.filter((i) => i.kind === 'file' && i.video === true && i.audio === false && i.duration);
    const sound = items.filter((i) => i.kind === 'file' && i.video === false && i.audio === true && i.duration);
    const pairs = [];
    for (const v of silent) {
      const a = sound.filter((s) => sameLength(s.duration, v.duration)).sort((x, y) => (y.size || 0) - (x.size || 0))[0];
      if (!a) continue;
      pairs.push({ kind: 'dash', url: v.url, audioUrl: a.url, duration: v.duration, width: v.width, height: v.height, video: true, audio: true,
        label: ['Video + sound', v.width && v.height ? `${v.width}×${v.height}` : '', clock(v.duration)].filter(Boolean).join(' · '), shaped: true });
    }
    // Several silent sizes of one video share their sound: keep the largest picture for each length.
    pairs.sort((a, b) => (b.width || 0) * (b.height || 0) - (a.width || 0) * (a.height || 0));
    const kept = pairs.filter((p, index) => pairs.findIndex((q) => sameLength(q.duration, p.duration)) === index);
    return kept.concat(items);
  }

  // The playing item, labelled as such, so the popup lists it first under "From this page".
  function labelPlaying(items) {
    return items.map((i) => {
      if (!i.playing) return i;
      const shape = [i.width && i.height ? `${i.width}×${i.height}` : '', i.duration ? clock(i.duration) : ''].filter(Boolean).join(' · ');
      const what = i.kind === 'dash' ? 'video + sound' : i.kind === 'hls' || i.kind === 'mpd' ? 'stream' : i.audio === false ? 'no sound' : '';
      return { ...i, label: ['Playing now', what, shape].filter(Boolean).join(' · '), shaped: true };
    });
  }

  // A site Haul does not save video from, so the popup says so instead of listing pieces that would not play.
  function unsupportedSite(tabUrl) {
    let host;
    try { host = new URL(tabUrl).host.toLowerCase(); } catch { return null; }
    if (['youtube.com', 'youtu.be', 'youtube-nocookie.com'].some((h) => host === h || host.endsWith('.' + h))) return 'Haul does not save video from YouTube.';
    return null;
  }

  const api = { classifyResponse, describeMedia, rangeTotal, unsupportedSite, bestTitle, sameLength, markPlaying, pairTracks, labelPlaying, formatSize, normaliseMediaURL, findInPage, findDashSets, pageVideoId, parseMPD, labelDashItems, pageReaderItem,
    hlsChildren, isAdHost, tidyMedia, recordMedia };
  root.HaulMedia = api;
  if (typeof module !== 'undefined') module.exports = api;
})(globalThis);
