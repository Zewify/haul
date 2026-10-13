// The Haul extension's background: talks to the Haul app on 127.0.0.1, catches downloads, serves the popup.
// It runs as a module service worker in Chrome and Safari alike; the shared lib files attach themselves to globalThis.
import './lib/links.js';
import './lib/media.js';
import './lib/request.js';
const api = globalThis.browser ?? globalThis.chrome;
const DEFAULTS = { port: 48512, token: null, capture: true, connected: false, media: false };
const STATUS_ALARM = 'haul-status';

async function settings() {
  const stored = await api.storage.local.get(DEFAULTS);
  return { ...DEFAULTS, ...stored };
}

function baseURL(port) { return `http://127.0.0.1:${port}`; }

function browserName() {
  const ua = navigator.userAgent;
  if (/Edg\//.test(ua)) return 'Microsoft Edge';
  if (/OPR\//.test(ua)) return 'Opera';
  if (/Vivaldi/.test(ua)) return 'Vivaldi';
  if (/Brave/.test(ua) || navigator.brave) return 'Brave';
  if (/Arc\//.test(ua)) return 'Arc';
  if (/Firefox\//.test(ua)) return 'Firefox';
  if (/Chrome\//.test(ua)) return 'Google Chrome';
  if (/Safari\//.test(ua)) return 'Safari';
  return 'Browser';
}

function clientKind() {
  if (typeof browser !== 'undefined' && /Safari\//.test(navigator.userAgent) && !/Chrome\//.test(navigator.userAgent)) return 'safari';
  if (/Firefox\//.test(navigator.userAgent)) return 'firefox';
  return 'chrome';
}

// MARK: Status

async function fetchStatus(port) {
  try {
    const response = await fetch(`${baseURL(port)}/status`, { cache: 'no-store' });
    if (!response.ok) return null;
    return await response.json();
  } catch {
    return null;
  }
}

async function refreshStatus() {
  const s = await settings();
  const status = await fetchStatus(s.port);
  const connected = !!status;
  const media = !!(status && status.features && status.features.media);
  if (connected !== s.connected || media !== s.media) {
    await api.storage.local.set({ connected, media });
  }
  await setBadge(connected ? (s.token ? '' : '!') : 'off', connected ? '#1098F4' : '#8E8E93');
  if (media) installMediaSniffer();
  return { status, connected, paired: !!s.token, media };
}

async function setBadge(text, color) {
  try {
    await api.action.setBadgeText({ text });
    if (text) await api.action.setBadgeBackgroundColor({ color });
  } catch { /* some browsers lack badges */ }
}

// MARK: Talking to the app

async function post(path, body) {
  const s = await settings();
  const headers = { 'Content-Type': 'application/json' };
  if (s.token) headers.Authorization = `Bearer ${s.token}`;
  try {
    const response = await fetch(`${baseURL(s.port)}${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
    let json = null;
    try { json = await response.json(); } catch { /* empty body */ }
    return { ok: response.ok, status: response.status, json };
  } catch (error) {
    return { ok: false, status: 0, json: { error: String(error) } };
  }
}

async function pair() {
  const result = await post('/pair', { client: clientKind(), name: browserName() });
  if (result.ok && result.json && result.json.token) {
    await api.storage.local.set({ token: result.json.token });
    await refreshStatus();

    return { ok: true };
  }
  return { ok: false, error: (result.json && result.json.error) || `Haul answered ${result.status || 'nothing'}` };
}

/// Sends a URL to the app. Returns {ok, error}.
async function handOver(url, { filename, referrer, pageTitle, kind } = {}) {
  if (!HaulRequest.isHTTP(url)) return { ok: false, error: 'Not an http link' };
  const s = await settings();
  if (!s.token) return { ok: false, error: 'Not connected to Haul' };
  let cookies = '';
  try { cookies = HaulRequest.cookieHeader(await api.cookies.getAll({ url })); } catch { /* no cookie permission */ }
  const body = HaulRequest.buildDownloadBody({ url, filename, referrer, cookies, userAgent: navigator.userAgent, pageTitle, kind });
  const result = await post(kind ? '/media' : '/downloads', body);
  if (result.ok) return { ok: true, id: result.json && result.json.id };
  if (result.status === 401) await api.storage.local.set({ token: null });
  return { ok: false, error: (result.json && result.json.error) || `Haul answered ${result.status || 'nothing'}` };
}

// MARK: Catching the browser's own downloads (Chromium only; Safari has no downloads API)

if (api.downloads && api.downloads.onCreated) {
  api.downloads.onCreated.addListener(async (item) => {
    const s = await settings();
    if (!s.capture || !s.token || !s.connected) return;
    if (item.byExtensionId) return;
    const url = item.finalUrl || item.url;
    if (!HaulRequest.isHTTP(url)) return;
    if (!(await fetchStatus(s.port))) { await api.storage.local.set({ connected: false }); return; }
    const filename = item.filename ? item.filename.split(/[\\/]/).pop() : undefined;
    const result = await handOver(url, { filename, referrer: item.referrer || undefined });
    if (result.ok) {
      try { await api.downloads.cancel(item.id); } catch { /* already done */ }
      try { await api.downloads.erase({ id: item.id }); } catch { /* fine */ }
    }
  });
}

// MARK: Context menus

async function installMenus() {
  if (!api.contextMenus) return;
  await new Promise((resolve) => api.contextMenus.removeAll(resolve));
  api.contextMenus.create({ id: 'haul-link', title: 'Download Link with Haul', contexts: ['link'] });
  api.contextMenus.create({ id: 'haul-media', title: 'Download with Haul', contexts: ['image', 'video', 'audio'] });
  api.contextMenus.create({ id: 'haul-page', title: 'Download This Page’s URL with Haul', contexts: ['page'] });
}

if (api.contextMenus) {
  api.contextMenus.onClicked.addListener(async (info, tab) => {
    const url = info.linkUrl || info.srcUrl || info.pageUrl;
    const result = await handOver(url, { referrer: info.pageUrl, pageTitle: tab && tab.title });
    if (!result.ok) await notify('Haul could not take that download', result.error);
  });
}

async function notify(title, message) {
  try {
    if (api.notifications) {
      await api.notifications.create({ type: 'basic', iconUrl: 'icons/icon-128.png', title, message });
    }
  } catch { /* no notifications permission */ }
}

// MARK: Media sniffing (direct edition only; installed when the app reports it)

const mediaByTab = new Map();
let snifferInstalled = false;

function installMediaSniffer() {
  if (snifferInstalled || !api.webRequest || !api.webRequest.onHeadersReceived) return;
  snifferInstalled = true;
  api.webRequest.onHeadersReceived.addListener((details) => {
    if (details.tabId < 0) return;
    const header = (details.responseHeaders || []).find((h) => h.name.toLowerCase() === 'content-type');
    const kind = HaulMedia.classifyResponse(details.url, header && header.value);
    if (!kind) return;
    const url = HaulMedia.normaliseMediaURL(details.url);
    const list = mediaByTab.get(details.tabId) || [];
    if (list.some((item) => item.url === url)) return;
    // The size is only meaningful when the response was the whole file, not one chunk of it.
    const length = url === details.url ? (details.responseHeaders || []).find((h) => h.name.toLowerCase() === 'content-length') : null;
    list.push({ url, kind, contentType: header && header.value.split(';')[0], size: length ? Number(length.value) : undefined, seen: Date.now() });
    if (list.length > 30) list.shift();
    mediaByTab.set(details.tabId, list);
    api.action.setBadgeText({ text: String(list.length), tabId: details.tabId });
  }, { urls: ['<all_urls>'], types: ['xmlhttprequest', 'media', 'other', 'main_frame', 'sub_frame'] }, ['responseHeaders']);

  api.tabs.onRemoved.addListener((tabId) => mediaByTab.delete(tabId));
  api.webNavigation && api.webNavigation.onCommitted && api.webNavigation.onCommitted.addListener((details) => {
    if (details.frameId === 0) mediaByTab.delete(details.tabId);
  });
}

/// What the page's own source says about its video: muxed progressive files the sniffer never sees as one request.
async function pageItems(tabId) {
  try {
    const found = await api.tabs.sendMessage(tabId, { type: 'scan' });
    return Array.isArray(found) ? found : [];
  } catch {
    return [];
  }
}

// MARK: Messages from the popup and content scripts

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    switch (message && message.type) {
      case 'status': {
        const state = await refreshStatus();

        const s = await settings();
        const tabId = message.tabId;
        let items = tabId != null ? (mediaByTab.get(tabId) || []) : [];
        if (state.media && tabId != null) items = (await pageItems(tabId)).concat(items);
        return { ...state, capture: s.capture, port: s.port, media: state.media, items };
      }
      case 'pair': return pair();
      case 'download': return handOver(message.url, { referrer: message.referrer || (sender.tab && sender.tab.url), pageTitle: message.pageTitle || (sender.tab && sender.tab.title) });
      case 'grab': return handOver(message.item.url, { referrer: message.referrer, pageTitle: message.pageTitle, kind: message.item.kind });
      case 'setCapture': await api.storage.local.set({ capture: !!message.value }); return { ok: true };
      case 'setPort': await api.storage.local.set({ port: Number(message.value) || 48512 }); return refreshStatus();

      case 'disconnect': await api.storage.local.set({ token: null }); return refreshStatus();

      default: return { ok: false, error: 'Unknown message' };
    }
  })().then(sendResponse, (error) => sendResponse({ ok: false, error: String(error) }));
  return true;
});

// MARK: Lifecycle

api.runtime.onInstalled.addListener(() => { installMenus(); refreshStatus(); });
api.runtime.onStartup && api.runtime.onStartup.addListener(() => { installMenus(); refreshStatus(); });
if (api.alarms) {
  api.alarms.create(STATUS_ALARM, { periodInMinutes: 0.5 });
  api.alarms.onAlarm.addListener((alarm) => { if (alarm.name === STATUS_ALARM) refreshStatus(); });
}
refreshStatus();
globalThis.haul = { fetchStatus, pair, handOver, refreshStatus, settings };
