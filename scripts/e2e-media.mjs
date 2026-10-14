// End-to-end check of the direct edition's media grabber against a real page: launches a throwaway Chrome with the
// extension, pairs it, opens the page, waits for playback traffic, prints what the sniffer found, grabs the first
// HLS item (or the largest file), accepts Haul's catch panel with Return, and waits for a file to land.
//   HAUL_CHROME=<chrome-for-testing-binary> node scripts/e2e-media.mjs <page-url> [seconds-to-watch]
// Needs a running Haul.
import { spawn, execFile } from 'node:child_process';
import { mkdtempSync, rmSync, readdirSync, statSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';

const [pageURL, watchArg] = process.argv.slice(2);
if (!pageURL) { console.error('usage: e2e-media.mjs <page-url> [seconds]'); process.exit(2); }
const watchSeconds = Number(watchArg || 12);
const port = 9333;
const profile = mkdtempSync(join(tmpdir(), 'haul-chrome-'));
const extension = new URL('../Extension', import.meta.url).pathname;
const binary = process.env.HAUL_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const chrome = spawn(binary, [`--user-data-dir=${profile}`, `--load-extension=${extension}`, `--remote-debugging-port=${port}`,
  '--no-first-run', '--no-default-browser-check', '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const osa = (script) => new Promise((resolve) => execFile('osascript', ['-e', script], (e, out) => resolve(e ? null : out.trim())));
const allowScript = 'tell application "System Events" to tell process "Haul"\nset clicked to false\nrepeat with w in windows\nif exists button "Allow" of w then\nclick button "Allow" of w\nset clicked to true\nend if\nend repeat\nif not clicked then error "no alert"\nend tell';

async function targets() { try { return await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch { return []; } }
async function waitFor(predicate, label, tries = 60) {
  for (let i = 0; i < tries; i++) { const found = (await targets()).find(predicate); if (found) return found; await sleep(500); }
  throw new Error(`timed out waiting for ${label}`);
}
function connect(target) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let id = 0; const pending = new Map();
  ws.addEventListener('message', (m) => { const msg = JSON.parse(m.data); if (pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); } });
  const ready = new Promise((r) => ws.addEventListener('open', r));
  return { ready, send: (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); }), close: () => ws.close() };
}
const snapshot = () => Object.fromEntries(readdirSync(join(homedir(), 'Downloads')).map((f) => [f, statSync(join(homedir(), 'Downloads', f)).size]));

let failed = false;
try {
  const first = await waitFor((t) => t.type === 'page', 'a page');
  const session = connect(first); await session.ready;
  await session.send('Page.navigate', { url: 'chrome://extensions/' });
  await sleep(1500);
  const info = await session.send('Runtime.evaluate', { expression: `new Promise(res => chrome.developerPrivate.getExtensionsInfo({includeDisabled: true}, res)).then(list => JSON.stringify(list.filter(e => e.name === 'Haul').map(e => e.id)))`, awaitPromise: true, returnByValue: true });
  const [id] = JSON.parse(info.result.result.value);
  if (!id) throw new Error('the Haul extension did not load');
  await session.send('Page.navigate', { url: `chrome-extension://${id}/popup.html` });
  await sleep(1200);
  const ask = async (message) => {
    const r = await session.send('Runtime.evaluate', { expression: `chrome.runtime.sendMessage(${JSON.stringify(message)}).then(x => JSON.stringify(x))`, awaitPromise: true, returnByValue: true });
    if (r.result.exceptionDetails) throw new Error(r.result.exceptionDetails.exception.description);
    return JSON.parse(r.result.result.value);
  };
  const status = await ask({ type: 'status' });
  if (!status.connected) throw new Error('Haul is not answering on 48512');
  if (!status.media) throw new Error('this Haul reports no media grabber');
  const approver = (async () => { for (let i = 0; i < 24; i++) { await sleep(500); if (await osa(allowScript) !== null) return true; } return false; })();
  const paired = await ask({ type: 'pair' });
  console.log('pair', JSON.stringify(paired), 'approver clicked:', await approver);
  if (!paired.ok) throw new Error('pairing failed');

  // A second tab for the page, so the popup tab keeps talking to the background.
  const created = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  const pageTarget = await waitFor((t) => t.id === created.id, 'the new tab');
  const page = connect(pageTarget); await page.ready;
  await page.send('Page.navigate', { url: pageURL });
  console.log(`watching ${pageURL} for ${watchSeconds}s`);
  await sleep(watchSeconds * 1000);
  const tabs = await session.send('Runtime.evaluate', { expression: `chrome.tabs.query({}).then(t => JSON.stringify(t.map(x => ({id: x.id, url: x.url, title: x.title}))))`, awaitPromise: true, returnByValue: true });
  const tab = JSON.parse(tabs.result.result.value).find((t) => t.url && t.url.startsWith(pageURL.split('?')[0].slice(0, 30)));
  if (!tab) throw new Error('could not find the page tab');
  console.log('page title:', tab.title, '| url:', tab.url);
  const state = await ask({ type: 'status', tabId: tab.id, tabUrl: tab.url });
  console.log(`sniffed ${state.items.length} item(s):`);
  for (const item of state.items) console.log(`  ${item.kind}  ${item.label || item.contentType || '-'}  ${item.size || '?'}  ${item.url.slice(0, 100)}`);
  const pick = state.items.find((i) => i.kind === 'page') || state.items.find((i) => i.kind === 'dash' && /^This video/.test(i.label || '')) || state.items.find((i) => i.kind === 'dash') || state.items.find((i) => i.kind === 'hls')
    || state.items.filter((i) => i.kind === 'file').sort((a, b) => (b.size || 0) - (a.size || 0))[0];
  if (!pick) throw new Error('nothing to grab');
  console.log('grabbing', pick.kind, pick.url.slice(0, 120));
  const before = snapshot();
  const grabbed = await ask({ type: 'grab', item: pick, referrer: tab.url, pageTitle: tab.title });
  console.log('grab', JSON.stringify(grabbed));
  if (!grabbed.ok) throw new Error('grab refused');
  await sleep(2500);
  await osa('tell application "Haul" to activate');
  await sleep(300);
  await osa('tell application "System Events" to keystroke return');
  let landed = null;
  let lastSize = -1, stableFor = 0;
  for (let i = 0; i < 300; i++) {
    await sleep(1000);
    const now = snapshot();
    // A DASH grab writes "(video)" and "(audio)" parts first; only the joined file counts, once it stops growing.
    const fresh = Object.keys(now).filter((f) => !(f in before) && !f.endsWith('.haulpart') && !/ \((video|audio)\)\.mp4$/.test(f));
    if (!fresh.length) continue;
    const size = now[fresh[0]];
    stableFor = size === lastSize ? stableFor + 1 : 0;
    lastSize = size;
    if (stableFor >= 2) { landed = fresh.map((f) => `${f} (${now[f]} bytes)`); break; }
  }
  if (!landed) throw new Error('no finished file appeared in ~/Downloads within 4 minutes');
  console.log('landed', landed.join(', '));
  console.log('PASS');
  page.close(); session.close();
} catch (error) {
  failed = true;
  console.error('FAIL', error.message);
} finally {
  chrome.kill();
  await sleep(500);
  rmSync(profile, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
