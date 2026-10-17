// Which links the content script catches as file downloads. Shared by the background and content scripts;
// also loaded by the node tests.
(function (root) {
  const FILE_EXTENSIONS = [
    'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'zst',
    'dmg', 'pkg', 'iso', 'img', 'exe', 'msi', 'apk', 'ipa', 'deb', 'rpm', 'appimage', 'jar', 'whl',
    'mp4', 'm4v', 'mkv', 'avi', 'mov', 'webm', 'wmv', 'flv', 'mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg', 'opus',
    'pdf', 'epub', 'mobi', 'psd', 'ai', 'bin', 'safetensors', 'gguf', 'ckpt', 'pt', 'pth',
  ];
  const set = new Set(FILE_EXTENSIONS);

  function isFileLink(href, hasDownloadAttribute) {
    let url;
    try { url = new URL(href); } catch { return false; }
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
    if (hasDownloadAttribute) return true;
    const path = url.pathname;
    if (path.endsWith('/')) return false;
    const last = path.slice(path.lastIndexOf('/') + 1);
    const dot = last.lastIndexOf('.');
    if (dot < 0) return false;
    return set.has(last.slice(dot + 1).toLowerCase());
  }

  const api = { isFileLink, FILE_EXTENSIONS };
  root.KomizoLinks = api;
  if (typeof module !== 'undefined') module.exports = api;
})(globalThis);
