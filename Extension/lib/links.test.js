const { test } = require('node:test');
const assert = require('node:assert/strict');
const { isFileLink, FILE_EXTENSIONS } = require('./links.js');

test('links to archives, images of disks, installers and media are file links', () => {
  for (const url of ['https://x.com/a.zip', 'https://x.com/dl/App.dmg?x=1', 'http://x.com/f.tar.gz', 'https://x.com/v.MP4#t=1', 'https://x.com/doc.pdf', 'https://x.com/x.iso'])
    assert.equal(isFileLink(url), true, url);
});

test('pages, scripts, anchors and non-http links are not', () => {
  for (const url of ['https://x.com/', 'https://x.com/page.html', 'https://x.com/api/download', 'javascript:void(0)', 'mailto:a@b.c', 'ftp://x/a.zip', 'https://x.com/a.zip/', 'not a url'])
    assert.equal(isFileLink(url), false, url);
});

test('a download attribute makes any http link a file link', () => {
  assert.equal(isFileLink('https://x.com/export?id=1', true), true);
  assert.equal(isFileLink('javascript:void(0)', true), false);
});

test('the list has no dots and is lowercase', () => {
  for (const ext of FILE_EXTENSIONS) assert.match(ext, /^[a-z0-9]+$/);
});
