const { test } = require('node:test');
const assert = require('node:assert/strict');
const { classifyResponse, describeMedia } = require('./media.js');

test('HLS playlists by type or extension', () => {
  assert.equal(classifyResponse('https://c.com/v/master.m3u8', 'application/vnd.apple.mpegurl'), 'hls');
  assert.equal(classifyResponse('https://c.com/v/index.m3u8?token=1', 'text/plain'), 'hls');
  assert.equal(classifyResponse('https://c.com/v/playlist', 'application/x-mpegURL; charset=utf-8'), 'hls');
});

test('plain media files by type or extension', () => {
  assert.equal(classifyResponse('https://c.com/v/clip', 'video/mp4'), 'file');
  assert.equal(classifyResponse('https://c.com/a/song.mp3', 'application/octet-stream'), 'file');
  assert.equal(classifyResponse('https://c.com/v/clip.webm', ''), 'file');
  assert.equal(classifyResponse('https://c.com/v/clip.mov', 'binary/octet-stream'), 'file');
});

test('DASH manifests by type or extension', () => {
  assert.equal(classifyResponse('https://c.com/v/manifest.mpd', 'application/dash+xml'), 'mpd');
  assert.equal(classifyResponse('https://vod.example/v2/playlist.mpd?locale=en&pathsig=x', 'application/octet-stream'), 'mpd');
  assert.equal(classifyResponse('https://c.com/v/stream', 'application/dash+xml; charset=utf-8'), 'mpd');
});

test('stream segments, pages and images are ignored', () => {
  assert.equal(classifyResponse('https://c.com/v/seg-1.ts', 'video/mp2t'), null);
  assert.equal(classifyResponse('https://c.com/v/seg-1.m4s', 'video/iso.segment'), null);
  assert.equal(classifyResponse('https://c.com/', 'text/html'), null);
  assert.equal(classifyResponse('https://c.com/p.png', 'image/png'), null);
  assert.equal(classifyResponse('https://c.com/v/clip', undefined), null);
  assert.equal(classifyResponse('https://c.com/v/range', 'video/mp4', { status: 206, range: 'bytes 1000-2000/5000' }), 'file', 'ranged media responses still count');
});

test('describes a media item for the popup: what it is first, where it came from second', () => {
  assert.deepEqual(describeMedia({ url: 'https://c.com/v/master.m3u8', kind: 'hls' }), { title: 'Stream (HLS)', subtitle: 'c.com · master.m3u8' });
  assert.deepEqual(describeMedia({ url: 'https://c.com/v/manifest.mpd', kind: 'mpd', size: 2643 }), { title: 'Stream (DASH)', subtitle: 'c.com · manifest.mpd' }, 'no size: it is the playlist\'s, not the video\'s');
  assert.deepEqual(describeMedia({ url: 'https://c.com/v/clip.mp4', kind: 'file', size: 10485760, contentType: 'video/mp4' }), { title: 'Video (mp4) · 10.5 MB', subtitle: 'c.com · clip.mp4' });
  assert.deepEqual(describeMedia({ url: 'https://c.com/v/clip', kind: 'file', contentType: 'video/webm' }), { title: 'Video (webm)', subtitle: 'c.com · clip' });
  assert.deepEqual(describeMedia({ url: 'https://c.com/a/track', kind: 'file', contentType: 'audio/mp4' }), { title: 'Audio (mp4)', subtitle: 'c.com · track' });
  assert.deepEqual(describeMedia({ url: 'https://video.xx.fbcdn.net/v/AQPnrSrokbMLDufWCQ7y3NO00bw88F.mp4?x=1', kind: 'file', label: 'HD (video + audio)' }),
    { title: 'HD (video + audio)', subtitle: 'video.xx.fbcdn.net · AQPnrSrokbMLDufWCQ7y3NO00bw88F.mp4' });
  assert.deepEqual(describeMedia({ url: 'https://video.xx.fbcdn.net/v/AQP.mp4', kind: 'dash', label: 'This video · 720p · video + audio', duration: 90 }),
    { title: 'This video · 720p · video + audio · 1:30', subtitle: 'video.xx.fbcdn.net · AQP.mp4' });
});

const { normaliseMediaURL, findInPage, findDashSets, pageVideoId } = require('./media.js');

test('chunk range parameters are stripped so one stream is one item', () => {
  assert.equal(normaliseMediaURL('https://video.xx.fbcdn.net/o1/v/t2/f2/m366/AQN.mp4?efg=abc&bytestart=0&byteend=579646&_nc_cat=1'), 'https://video.xx.fbcdn.net/o1/v/t2/f2/m366/AQN.mp4?efg=abc&_nc_cat=1');
  assert.equal(normaliseMediaURL('https://c.com/v.mp4?range=0-100'), 'https://c.com/v.mp4');
  assert.equal(normaliseMediaURL('https://c.com/v.mp4'), 'https://c.com/v.mp4');
  assert.equal(normaliseMediaURL('nope'), 'nope');
});

test('progressive video urls are found in a page source, unescaped and deduped', () => {
  const html = '<script>{"browser_native_hd_url":"https:\\/\\/video.xx.fbcdn.net\\/v\\/hd.mp4?a=1\\u00261","browser_native_sd_url":"https:\\/\\/video.xx.fbcdn.net\\/v\\/sd.mp4?a=2"}</script>'
    + '<script>{"browser_native_hd_url":"https:\\/\\/video.xx.fbcdn.net\\/v\\/hd.mp4?a=1\\u00261"}</script>'
    + '<video src="https://cdn.example/clip.webm"></video>';
  const found = findInPage(html);
  assert.deepEqual(found, [
    { url: 'https://video.xx.fbcdn.net/v/hd.mp4?a=1&1', kind: 'file', label: 'HD (video + audio)' },
    { url: 'https://video.xx.fbcdn.net/v/sd.mp4?a=2', kind: 'file', label: 'SD (video + audio)' },
    { url: 'https://cdn.example/clip.webm', kind: 'file', label: 'Video on page' },
  ]);
  assert.deepEqual(findInPage('<p>nothing</p>'), []);
});

test('dash representation sets embedded in a page become joinable video + audio items, H.264 before AV1, the page video first', () => {
  const efg = (videoId, duration) => Buffer.from(JSON.stringify({ vencode_tag: 'dash', video_id: videoId, duration_s: duration })).toString('base64');
  const rep = (id, mime, codecs, w, h, bw, videoId) => `{"representation_id":"${id}","mime_type":"${mime.replace('/', '\\/')}","codecs":"${codecs}","base_url":"https:\\/\\/video.xx.fbcdn.net\\/v\\/${id}.mp4?efg=${efg(videoId, 90)}\\u00253D&oh=1","bandwidth":${bw},"height":${h},"width":${w},"segments":[{"start":0,"end":1}]}`;
  const set = (videoId, reps) => `{"initial_representation_ids":[],"representations":[${reps.join(',')}]}`;
  const html = '<script>' + JSON.stringify({ x: 1 }) + '"all_video_dash_prefetch_representations":[' + [
    set('111', [rep('a1', 'video/mp4', 'av01.0.08M.08', 1080, 1080, 900000, '111'), rep('a2', 'video/mp4', 'avc1.64001F', 720, 720, 800000, '111'), rep('a3', 'video/mp4', 'avc1.4D401E', 360, 360, 300000, '111'), rep('a4', 'audio/mp4', 'mp4a.40.5', 0, 0, 48000, '111'), rep('a5', 'audio/mp4', 'mp4a.40.2', 0, 0, 128000, '111')]),
    set('222', [rep('b1', 'video/mp4', 'avc1.64001F', 854, 480, 500000, '222'), rep('b2', 'audio/mp4', 'mp4a.40.2', 0, 0, 96000, '222')]),
  ].join(',') + '],"other":1</script>';
  const items = findDashSets(html, '222');
  assert.deepEqual(items.map((i) => ({ ...i, url: i.url.slice(0, 40), audioUrl: i.audioUrl.slice(0, 40) })), [
    { kind: 'dash', videoId: '222', url: 'https://video.xx.fbcdn.net/v/b1.mp4?efg=', audioUrl: 'https://video.xx.fbcdn.net/v/b2.mp4?efg=', label: 'This video · 480p H.264 · video + audio', duration: 90, width: 854, height: 480, codec: 'H.264', codecs: 'avc1.64001F' },
    { kind: 'dash', videoId: '111', url: 'https://video.xx.fbcdn.net/v/a2.mp4?efg=', audioUrl: 'https://video.xx.fbcdn.net/v/a5.mp4?efg=', label: 'Another video on this page · 720p H.264 · video + audio', duration: 90, width: 720, height: 720, codec: 'H.264', codecs: 'avc1.64001F' },
    { kind: 'dash', videoId: '111', url: 'https://video.xx.fbcdn.net/v/a1.mp4?efg=', audioUrl: 'https://video.xx.fbcdn.net/v/a5.mp4?efg=', label: 'Another video on this page · 1080p AV1 · video + audio · plays on newer Macs only', duration: 90, width: 1080, height: 1080, codec: 'AV1', codecs: 'av01.0.08M.08' },
  ], 'one item per codec family, H.264 first, the loudest audio, the page video first');
  assert.deepEqual(findDashSets('<p>none</p>', '1'), []);
  const vp9Only = '"all_video_dash_prefetch_representations":[' + set('333', [rep('c1', 'video/mp4', 'vp09.00.40.08', 1920, 1920, 900000, '333'), rep('c2', 'audio/mp4', 'mp4a.40.2', 0, 0, 96000, '333')]) + ']';
  assert.deepEqual(findDashSets(vp9Only, '333'), [], 'codecs a Mac cannot join are left out');
});

test('video ids beyond the safe integer range survive the efg decoding', () => {
  const efg = Buffer.from('{"vencode_tag":"dash","video_id":26934216426212982,"duration_s":900}').toString('base64');
  const html = '"all_video_dash_prefetch_representations":[{"initial_representation_ids":[],"representations":['
    + `{"representation_id":"v1","mime_type":"video\\/mp4","codecs":"avc1.64001F","base_url":"https:\\/\\/v.example\\/v1.mp4?efg=${efg}","bandwidth":1,"height":720,"width":720},`
    + `{"representation_id":"a1","mime_type":"audio\\/mp4","codecs":"mp4a.40.2","base_url":"https:\\/\\/v.example\\/a1.mp4?efg=${efg}","bandwidth":1,"height":0,"width":0}]}]`;
  const items = findDashSets(html, '26934216426212982');
  assert.equal(items.length, 1);
  assert.equal(items[0].videoId, '26934216426212982');
  assert.match(items[0].label, /^This video/);
  assert.equal(items[0].duration, 900);
});

test('the page video id comes from reel and watch urls', () => {
  assert.equal(pageVideoId('https://www.facebook.com/reel/26934216426212982'), '26934216426212982');
  assert.equal(pageVideoId('https://www.facebook.com/watch/?v=1234567890'), '1234567890');
  assert.equal(pageVideoId('https://www.facebook.com/someone/videos/987654/'), '987654');
  assert.equal(pageVideoId('https://example.com/page'), null);
});

const { parseMPD } = require('./media.js');

test('a DASH manifest becomes joinable items the same way the page table does', () => {
  const xml = `<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT0H15M0.0S" type="static">
  <Period>
    <AdaptationSet segmentAlignment="true" maxWidth="1080" mimeType="video/mp4">
      <Representation id="2297632240762264v" mimeType="video/mp4" codecs="avc1.64001F" width="720" height="720" bandwidth="800000" FBQualityLabel="720p"><BaseURL>https://video.xx.fbcdn.net/v/v720.mp4?x=1&amp;y=2</BaseURL><SegmentBase indexRange="804-2995"><Initialization range="0-803"/></SegmentBase></Representation>
      <Representation id="1693970385122294v" mimeType="video/mp4" codecs="av01.0.08M.08" width="1080" height="1080" bandwidth="900000"><BaseURL>https://video.xx.fbcdn.net/v/v1080.mp4</BaseURL></Representation>
    </AdaptationSet>
    <AdaptationSet segmentAlignment="true" mimeType="audio/mp4">
      <Representation id="1234a" mimeType="audio/mp4" codecs="mp4a.40.2" audioSamplingRate="48000" bandwidth="128000"><BaseURL>https://video.xx.fbcdn.net/v/a128.mp4</BaseURL></Representation>
      <Representation id="1235a" mimeType="audio/mp4" codecs="mp4a.40.5" bandwidth="48000"><BaseURL>https://video.xx.fbcdn.net/v/a48.mp4</BaseURL></Representation>
    </AdaptationSet>
  </Period></MPD>`;
  const items = parseMPD(xml, '26934216426212982');
  assert.deepEqual(items, [
    { kind: 'dash', videoId: '26934216426212982', url: 'https://video.xx.fbcdn.net/v/v720.mp4?x=1&y=2', audioUrl: 'https://video.xx.fbcdn.net/v/a128.mp4', label: 'This video · 720p H.264 · video + audio', duration: 900, width: 720, height: 720, codec: 'H.264', codecs: 'avc1.64001F' },
    { kind: 'dash', videoId: '26934216426212982', url: 'https://video.xx.fbcdn.net/v/v1080.mp4', audioUrl: 'https://video.xx.fbcdn.net/v/a128.mp4', label: 'This video · 1080p AV1 · video + audio · plays on newer Macs only', duration: 900, width: 1080, height: 1080, codec: 'AV1', codecs: 'av01.0.08M.08' },
  ]);
  assert.deepEqual(parseMPD('<html>login</html>', '1'), []);
});

const { labelDashItems } = require('./media.js');

test('the url names "This video"; what the player is fetching only decides when the url does not', () => {
  const items = [
    { kind: 'dash', videoId: '111', url: 'https://v.example/a-video.mp4?efg=1', audioUrl: 'https://v.example/a-audio.mp4?efg=1', height: 1080, codec: 'AV1', own: false },
    { kind: 'dash', videoId: '222', url: 'https://v.example/b-video.mp4?efg=2', audioUrl: 'https://v.example/b-audio.mp4?efg=2', height: 720, codec: 'H.264', own: false },
  ];
  const sniffed = ['https://v.example/b-audio.mp4?efg=2', 'https://v.example/unrelated.mp4'];
  const labelled = labelDashItems(items, sniffed, null);
  assert.deepEqual(labelled.map((i) => [i.videoId, i.label]), [
    ['222', 'This video · 720p H.264 · video + audio'],
    ['111', 'Another video on this page · 1080p AV1 · video + audio · plays on newer Macs only'],
  ], 'without a url id, the sniffed match wins and comes first');
  const byUrl = labelDashItems(items, sniffed, '111');
  assert.equal(byUrl[0].videoId, '111', 'the url id wins over what is playing');
  assert.match(byUrl[0].label, /^This video/);
  assert.match(byUrl[1].label, /^Another video/);
  const none = labelDashItems(items, [], null);
  assert.ok(none.every((i) => /^Another video/.test(i.label) === false && /^Video on this page/.test(i.label)), 'with nothing to go on, nothing is called "another"');
});

test('dash rows say which video they are instead of a hash', () => {
  assert.deepEqual(describeMedia({ url: 'https://scontent.xx.fbcdn.net/v/AQNwtkB9F6JmSviz4edJ.mp4', kind: 'dash', videoId: '26934216426212982', label: 'This video · 1080p AV1 · video + audio', duration: 900 }),
    { title: 'This video · 1080p AV1 · video + audio · 15:00', subtitle: 'scontent.xx.fbcdn.net · video 26934216426212982' });
});

const { pageReaderItem } = require('./media.js');

test('a Facebook video page gets an item that hands the page itself to Haul', () => {
  assert.deepEqual(pageReaderItem('https://www.facebook.com/reel/1619008336628300'),
    { kind: 'page', url: 'https://www.facebook.com/reel/1619008336628300', videoId: '1619008336628300', label: 'This video · 720p H.264 · Haul reads the page' });
  assert.deepEqual(pageReaderItem('https://www.facebook.com/watch/?v=123'), { kind: 'page', url: 'https://www.facebook.com/watch/?v=123', videoId: '123', label: 'This video · 720p H.264 · Haul reads the page' });
  assert.equal(pageReaderItem('https://www.facebook.com/'), null);
  assert.equal(pageReaderItem('https://example.com/reel/1'), null);
});

const { hlsChildren, isAdHost, tidyMedia, recordMedia } = require('./media.js');

test('a master playlist names its variants and its separate audio; a media playlist names nothing', () => {
  // TED's shape: variants with an audio group, I-frame playlists, an audio rendition and subtitles.
  const master = [
    '#EXTM3U',
    '#EXT-X-STREAM-INF:BANDWIDTH=1104484,RESOLUTION=640x480,AUDIO="audio0",SUBTITLES="subs"',
    'index-f9-v1.m3u8?intro_master_id=9294',
    '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=51702,URI="iframes-f9-v1.m3u8?intro_master_id=9294"',
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio0",NAME="medium",DEFAULT=YES,URI="index-f8-a1.m3u8?intro_master_id=9294"',
    '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="pt-br",URI="/project_masters/1253/subtitles/pt-br.m3u8"',
  ].join('\n');
  assert.deepEqual(hlsChildren(master, 'https://hls.ted.com/project_masters/1253/manifest.m3u8?intro_master_id=9294'), [
    'https://hls.ted.com/project_masters/1253/index-f9-v1.m3u8?intro_master_id=9294',
    'https://hls.ted.com/project_masters/1253/iframes-f9-v1.m3u8?intro_master_id=9294',
    'https://hls.ted.com/project_masters/1253/index-f8-a1.m3u8?intro_master_id=9294',
    'https://hls.ted.com/project_masters/1253/subtitles/pt-br.m3u8',
  ]);
  assert.deepEqual(hlsChildren('#EXTM3U\n#EXTINF:4,\nseg1.ts\n#EXT-X-ENDLIST', 'https://c.com/v/index.m3u8'), []);
  assert.deepEqual(hlsChildren('<html>', 'https://c.com/'), []);
});

test('ad networks are recognised by host, the site itself is not', () => {
  assert.ok(isAdHost('https://rr3---sn-ojhoai-5i.c.2mdn.net/videoplayback/id/0026/itag/37/source/web_video_ads'));
  assert.ok(isAdHost('https://media.innity.net/202609_58056/video1.mp4'));
  assert.ok(isAdHost('https://pubads.g.doubleclick.net/x.mp4'));
  assert.ok(isAdHost('https://www.viously.com/video/hls/PynrhUHmVJG/index.m3u8?pw=143'), 'the outstream player w3schools embeds');
  assert.ok(!isAdHost('https://pu.tedcdn.com/consus/videos/1253/segment-1.ts'));
  assert.ok(!isAdHost('https://not2mdn.net/v.mp4'));
});

test('the popup lists the stream, not its pieces, its variant playlists or the ads around it', () => {
  const items = [
    { kind: 'hls', url: 'https://hls.ted.com/m/manifest.m3u8', children: ['https://hls.ted.com/m/index-f9-v1.m3u8', 'https://hls.ted.com/m/index-f8-a1.m3u8'] },
    { kind: 'hls', url: 'https://hls.ted.com/m/index-f9-v1.m3u8' },
    { kind: 'hls', url: 'https://hls.ted.com/m/index-f8-a1.m3u8' },
    { kind: 'file', url: 'https://rr3---sn-x.c.2mdn.net/videoplayback/ad.mp4' },
    { kind: 'file', url: 'https://media.innity.net/a/video2.mp4' },
    { kind: 'mpd', url: 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd' },
    { kind: 'file', url: 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_a64k/bbb_a64k_4.m4a' },
    { kind: 'file', url: 'https://other.example/trailer.mp4' },
  ];
  assert.deepEqual(tidyMedia(items).map((i) => i.url), [
    'https://hls.ted.com/m/manifest.m3u8',
    'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd',
    'https://other.example/trailer.mp4',
  ]);
  // Without a stream, plain files are all the page has, so they all stay (ads still go).
  const plain = [{ kind: 'file', url: 'https://www.w3schools.com/html/mov_bbb.mp4' }, { kind: 'file', url: 'https://x.2mdn.net/ad.mp4' }];
  assert.deepEqual(tidyMedia(plain).map((i) => i.url), ['https://www.w3schools.com/html/mov_bbb.mp4']);
});

test('a flood of segments never pushes the stream out of the list', () => {
  const list = [];
  assert.ok(recordMedia(list, { kind: 'mpd', url: 'https://c.com/v.mpd' }, 5));
  for (let n = 0; n < 40; n++) recordMedia(list, { kind: 'file', url: `https://c.com/seg_${n}.m4v` }, 5);
  assert.equal(list.length, 5);
  assert.equal(list[0].url, 'https://c.com/v.mpd');
  assert.equal(list[4].url, 'https://c.com/seg_39.m4v');
  assert.equal(recordMedia(list, { kind: 'mpd', url: 'https://c.com/v.mpd' }, 5), false, 'a repeat is not recorded twice');
});

const { rangeTotal, bestTitle, markPlaying, pairTracks, labelPlaying } = require('./media.js');

test('a refused response is not offered, and a track fetched in pieces is a whole file', () => {
  // Dailymotion's player asks a director that answers 403, then fetches the real playlist elsewhere.
  assert.equal(classifyResponse('https://cdndirector.dailymotion.com/cdn/manifest/video/x.m3u8', 'text/html', { status: 403 }), null);
  assert.equal(classifyResponse('https://dmxleo.dailymotion.com/cdn/manifest/video/x.m3u8', 'application/xml', { status: 200 }), 'hls');
  // Bilibili fetches each whole track as .m4s in byte ranges; a template's segments carry no total, or a small one.
  assert.equal(classifyResponse('https://upos.bilivideo.com/x/123-1-30080.m4s?e=1', 'video/mp4', { status: 206, range: 'bytes 0-1023/48211234' }), 'file');
  assert.equal(classifyResponse('https://c.com/v/seg_12.m4s', 'video/mp4', { status: 200 }), null);
  assert.equal(classifyResponse('https://c.com/v/seg_12.m4s', 'video/iso.segment', { status: 206, range: 'bytes 0-999/40000' }), null);
  assert.equal(rangeTotal('bytes 0-1023/48211234'), 48211234);
  assert.equal(rangeTotal('bytes 0-1023/*'), undefined);
});

test('the page title, unless it is only the site name', () => {
  assert.equal(bestTitle('X', 'NASA on X: "Two jets over the Mojave"'), 'NASA on X: "Two jets over the Mojave"');
  assert.equal(bestTitle('Instagram', 'NASA on Instagram: "Saturn"'), 'NASA on Instagram: "Saturn"');
  assert.equal(bestTitle('Natiming sa checkpoint | TikTok', 'Mel Palm on TikTok'), 'Natiming sa checkpoint | TikTok');
  assert.equal(bestTitle('demo - Twitch', 'Twitch'), 'demo - Twitch');
  assert.equal(bestTitle('', 'Only og'), 'Only og');
});

test('a direct player is matched by its source', () => {
  // Reddit's post plays its packaged MP4 directly; a promoted video streams from the same CDN beside it.
  const items = [
    { kind: 'hls', url: 'https://v.redd.it/ad123/HLSPlaylist.m3u8?f=hd', duration: 111 },
    { kind: 'file', url: 'https://packaged-media.redd.it/post/pb/m2-res_600p.mp4?m=DASHPlaylist.mpd', duration: 39, video: true, audio: true },
  ];
  const marked = markPlaying(items, [{ src: 'https://packaged-media.redd.it/post/pb/m2-res_600p.mp4?m=DASHPlaylist.mpd', duration: 39, width: 480, height: 600 }]);
  assert.equal(marked[0].url, items[1].url);
  assert.ok(marked[0].playing);
  assert.ok(!marked[1].playing);
});

test('a blob: player is matched by its length, not by being the biggest file', () => {
  // TikTok: the page's 6-second video, and a 74-second neighbour the feed preloaded, which is larger.
  const items = [
    { kind: 'file', url: 'https://v16.tiktok.com/neighbour.mp4', duration: 73.8, video: true, audio: true, width: 720, height: 1280, size: 5641950 },
    { kind: 'file', url: 'https://v16.tiktok.com/this.mp4', duration: 6.2, video: true, audio: true, width: 720, height: 1280, size: 435019 },
  ];
  const marked = markPlaying(items, [{ src: 'blob:https://www.tiktok.com/abc', duration: 6, width: 720, height: 1280 }]);
  assert.equal(marked[0].url, 'https://v16.tiktok.com/this.mp4');
  assert.ok(marked[0].playing);
  assert.deepEqual(markPlaying(items, []), items, 'nothing playing, nothing marked');
  assert.ok(!markPlaying(items, [{ src: 'blob:x', duration: 300 }]).some((i) => i.playing), 'no length matches, nothing marked');
});

test('silent video and its sound are paired, and the pair is what plays', () => {
  // Instagram: video-only tracks at two sizes and one audio-only track of the same length, plus a neighbour's.
  const items = [
    { kind: 'file', url: 'https://ig/v360.mp4', duration: 43.8, video: true, audio: false, width: 360, height: 640, size: 900000 },
    { kind: 'file', url: 'https://ig/v720.mp4', duration: 43.7, video: true, audio: false, width: 718, height: 1276, size: 1295721 },
    { kind: 'file', url: 'https://ig/a.mp4', duration: 43.8, video: false, audio: true, size: 700000 },
    { kind: 'file', url: 'https://ig/other-a.mp4', duration: 12, video: false, audio: true },
  ];
  const paired = pairTracks(items);
  assert.equal(paired[0].kind, 'dash');
  assert.equal(paired[0].url, 'https://ig/v720.mp4', 'the larger picture');
  assert.equal(paired[0].audioUrl, 'https://ig/a.mp4');
  assert.equal(paired.filter((i) => i.kind === 'dash').length, 1, 'one pair per video, not per size');
  const playing = labelPlaying(markPlaying(paired, [{ src: 'blob:https://www.instagram.com/x', duration: 43.7, width: 718, height: 1276 }]));
  assert.equal(playing[0].kind, 'dash');
  assert.equal(playing[0].label, 'Playing now · video + sound · 718×1276 · 0:44');
  assert.deepEqual(describeMedia(playing[0]).title, 'Playing now · video + sound · 718×1276 · 0:44');
});

test('what Haul learned shows in the list', () => {
  assert.equal(describeMedia({ kind: 'file', url: 'https://c.com/v.mp4', contentType: 'video/mp4', video: true, audio: false, width: 1280, height: 720, duration: 65 }).title,
    'Video (mp4) · no sound · 1280×720 · 1:05');
  assert.equal(describeMedia({ kind: 'file', url: 'https://c.com/a.mp4', contentType: 'video/mp4', video: false, audio: true, duration: 3725 }).title, 'Audio (mp4) · 1:02:05');
  assert.equal(describeMedia({ kind: 'hls', url: 'https://c.com/live.m3u8', live: true }).title, 'Live stream · cannot be saved');
  assert.equal(describeMedia({ kind: 'hls', url: 'https://c.com/once.m3u8', error: 'The server answered 403' }).title, 'Stream · Haul cannot open this link');
});

const { unsupportedSite } = require('./media.js');

test('YouTube is named as unsupported, everything else is not', () => {
  for (const url of ['https://www.youtube.com/watch?v=abc', 'https://m.youtube.com/shorts/x', 'https://youtu.be/abc', 'https://music.youtube.com/watch?v=1']) {
    assert.equal(unsupportedSite(url), 'Haul does not save video from YouTube.', url);
  }
  assert.equal(unsupportedSite('https://notyoutube.com/v'), null);
  assert.equal(unsupportedSite('https://vimeo.com/1'), null);
  assert.equal(unsupportedSite('not a url'), null);
});
