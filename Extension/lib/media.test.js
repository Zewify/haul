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

test('stream segments, DASH, pages and images are ignored', () => {
  assert.equal(classifyResponse('https://c.com/v/seg-1.ts', 'video/mp2t'), null);
  assert.equal(classifyResponse('https://c.com/v/seg-1.m4s', 'video/iso.segment'), null);
  assert.equal(classifyResponse('https://c.com/v/manifest.mpd', 'application/dash+xml'), null);
  assert.equal(classifyResponse('https://c.com/', 'text/html'), null);
  assert.equal(classifyResponse('https://c.com/p.png', 'image/png'), null);
  assert.equal(classifyResponse('https://c.com/v/clip', undefined), null);
  assert.equal(classifyResponse('https://c.com/v/range', 'video/mp4', { status: 206, range: 'bytes 1000-2000/5000' }), 'file', 'ranged media responses still count');
});

test('describes a media item for the popup', () => {
  assert.equal(describeMedia({ url: 'https://c.com/v/master.m3u8', kind: 'hls' }), 'master.m3u8 · HLS stream');
  assert.equal(describeMedia({ url: 'https://c.com/v/clip.mp4', kind: 'file', size: 10485760 }), 'clip.mp4 · 10.5 MB');
  assert.equal(describeMedia({ url: 'https://c.com/v/clip', kind: 'file', contentType: 'video/webm' }), 'clip · video/webm');
});
