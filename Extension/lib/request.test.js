const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildDownloadBody, cookieHeader, isHTTP } = require('./request.js');

test('cookie header joins name=value pairs', () => {
  assert.equal(cookieHeader([{ name: 'a', value: '1' }, { name: 'b', value: 'x y' }]), 'a=1; b=x y');
  assert.equal(cookieHeader([]), '');
  assert.equal(cookieHeader(undefined), '');
});

test('body carries only what is set', () => {
  const body = buildDownloadBody({ url: 'https://x.com/a.zip', filename: 'a.zip', referrer: 'https://x.com/', cookies: 'a=1', userAgent: 'UA', pageTitle: 'T', kind: 'hls' });
  assert.deepEqual(body, { url: 'https://x.com/a.zip', filename: 'a.zip', referrer: 'https://x.com/', cookies: 'a=1', userAgent: 'UA', pageTitle: 'T', kind: 'hls' });
  assert.deepEqual(buildDownloadBody({ url: 'https://x.com/a.zip', cookies: '', filename: '' }), { url: 'https://x.com/a.zip' });
});

test('only http and https urls are sent', () => {
  assert.equal(isHTTP('https://x.com/a'), true);
  assert.equal(isHTTP('http://x.com/a'), true);
  assert.equal(isHTTP('file:///etc/passwd'), false);
  assert.equal(isHTTP('blob:https://x.com/abc'), false);
  assert.equal(isHTTP('nope'), false);
});
