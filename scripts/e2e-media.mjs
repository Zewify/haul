// End-to-end check of the media grabber against a real page: launches a throwaway Chrome with the extension, pairs
// it, opens the page, starts playback, prints what the sniffer found, grabs the best item, presses Start in Haul's
// catch panel, and follows the new download in Haul's own library until it finishes, failing on a silent result.
//   HAUL_CHROME=<chrome-for-testing-binary> node scripts/e2e-media.mjs <page-url> [seconds-to-watch]
// Needs a running Haul.
import { spawn, execFile } from 'node:child_process';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { pressStart } from './catch-panel.mjs';

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
const libraryPath = join(homedir(), 'Library/Containers/com.zewify.haul/Data/Library/Application Support/Haul/library.json');
const library = () => { try { return JSON.parse(readFileSync(libraryPath, 'utf8')).downloads || []; } catch { return []; } };
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
  await sleep(5000);
  // Muted playback may start on its own; a click on the player is what a person would do otherwise.
  const play = `(() => { const v = [...document.querySelectorAll('video')]; v.forEach((x) => { x.muted = true; x.play().catch(() => {}); });
    const b = document.querySelector('[aria-label*="Play" i], button[class*="play" i], .vjs-big-play-button'); if (b && !v.some((x) => !x.paused)) b.click();
    return v.filter((x) => !x.paused).length + ' of ' + v.length + ' video element(s) playing'; })()`;
  console.log('playback:', (await page.send('Runtime.evaluate', { expression: play, returnByValue: true })).result?.result?.value);
  await sleep(watchSeconds * 1000);
  const tabs = await session.send('Runtime.evaluate', { expression: `chrome.tabs.query({}).then(t => JSON.stringify(t.map(x => ({id: x.id, url: x.url, title: x.title}))))`, awaitPromise: true, returnByValue: true });
  // Two tabs exist: the extension's popup page and the page under test, whatever its URL has become since.
  const tab = JSON.parse(tabs.result.result.value).find((t) => t.url && !t.url.startsWith('chrome-extension:') && t.url !== 'about:blank');
  if (!tab) throw new Error('could not find the page tab');
  console.log('page title:', tab.title, '| url:', tab.url);
  const state = await ask({ type: 'status', tabId: tab.id, tabUrl: tab.url });
  console.log(`sniffed ${state.items.length} item(s):`);
  for (const item of state.items) console.log(`  ${item.kind}  ${item.label || item.contentType || '-'}  ${item.size || '?'}  ${item.url.slice(0, 100)}`);
  const pick = state.items.find((i) => i.kind === 'page') || state.items.find((i) => i.kind === 'dash' && /^This video/.test(i.label || '')) || state.items.find((i) => i.kind === 'dash')
    || state.items.find((i) => i.kind === 'hls' || i.kind === 'mpd') || state.items.filter((i) => i.kind === 'file').sort((a, b) => (b.size || 0) - (a.size || 0))[0];
  if (!pick) throw new Error('nothing to grab');
  console.log('grabbing', pick.kind, pick.url.slice(0, 120));
  const before = new Set(library().map((d) => d.id));
  const grabbed = await ask({ type: 'grab', item: pick, referrer: tab.url, pageTitle: tab.title });
  console.log('grab', JSON.stringify(grabbed));
  if (!grabbed.ok) throw new Error('grab refused');
  if (!(await pressStart())) throw new Error('the catch panel never offered Start (its error, if any, is on screen)');
  let download = null;
  for (let i = 0; i < 600; i++) {
    await sleep(1000);
    download = library().find((d) => !before.has(d.id));
    const state = download && Object.keys(download.state)[0];
    if (state === 'finished') {
      // Haul inspects a finished grab and notes a silent one a moment later.
      await sleep(3000);
      download = library().find((d) => d.id === download.id);
      break;
    }
    if (state === 'failed' || state === 'cancelled') throw new Error(`Haul ${state} it: ${JSON.stringify(download.state)}`);
  }
  if (!download || !download.state.finished) throw new Error('the download did not finish within 10 minutes');
  console.log('landed', download.finalPath, `(${download.size} bytes)`, download.mediaNote ? `· ${download.mediaNote}` : '');
  if (download.mediaNote) throw new Error(`the file is not whole: ${download.mediaNote}`);
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
