// End-to-end check of the Chrome extension against a running Haul: launches a throwaway Chrome with the
// extension loaded, pairs it (clicking Allow in Haul through System Events), clicks a file link on a test page,
// accepts Haul's catch panel with Return, and waits for the file to land.
//   HAUL_CHROME=<chrome-for-testing-binary> node scripts/e2e-chrome.mjs <test-page-url> <expected-file-in-~/Downloads>
import { spawn, execFile } from 'node:child_process';
import { existsSync, statSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';

const [pageURL, expectedName] = process.argv.slice(2);
if (!pageURL || !expectedName) { console.error('usage: e2e-chrome.mjs <page-url> <expected-file>'); process.exit(2); }
const port = 9333;
const profile = mkdtempSync(join(tmpdir(), 'haul-chrome-'));
const extension = new URL('../Extension', import.meta.url).pathname;
// Google Chrome 137 and later ignores --load-extension; Chrome for Testing or Chromium honours it.
// Point HAUL_CHROME at such a binary (for example one from `npx @puppeteer/browsers install chrome@stable`).
const binary = process.env.HAUL_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const chrome = spawn(binary, [
  `--user-data-dir=${profile}`, `--load-extension=${extension}`, `--remote-debugging-port=${port}`,
  '--no-first-run', '--no-default-browser-check', 'about:blank',
], { stdio: 'ignore' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const osa = (script) => new Promise((resolve) => execFile('osascript', ['-e', script], (e, out) => resolve(e ? null : out.trim())));

async function targets() {
  try { return await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch { return []; }
}
async function waitFor(predicate, label, tries = 60) {
  for (let i = 0; i < tries; i++) { const found = (await targets()).find(predicate); if (found) return found; await sleep(500); }
  throw new Error(`timed out waiting for ${label}`);
}
function connect(target) {
  const ws = new WebSocket(target.webSocketDebuggerUrl);
  let id = 0; const pending = new Map();
  ws.addEventListener('message', (m) => { const msg = JSON.parse(m.data); if (pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); } });
  const ready = new Promise((r) => ws.addEventListener('open', r));
  return {
    ready,
    send: (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); }),
    close: () => ws.close(),
  };
}
async function evaluate(target, expression) {
  const c = connect(target); await c.ready;
  // A worker that was started for the debugger waits until told to run.
  await c.send('Runtime.runIfWaitingForDebugger');
  const result = await c.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  c.close();
  if (result.result && result.result.exceptionDetails) throw new Error(JSON.stringify(result.result.exceptionDetails));
  return result.result && result.result.result && result.result.result.value;
}

let failed = false;
try {
  // Haul's worker is idle until something talks to it, so it is not listed; find the extension's id through
  // the extensions page, then drive the background through the extension's own popup page in a tab.
  const first = await waitFor((t) => t.type === 'page', 'a page');
  const extensionsPage = connect(first); await extensionsPage.ready;
  await extensionsPage.send('Page.navigate', { url: 'chrome://extensions/' });
  await sleep(1500);
  const info = await extensionsPage.send('Runtime.evaluate', { expression: `new Promise(res => chrome.developerPrivate.getExtensionsInfo({includeDisabled: true}, res)).then(list => JSON.stringify(list.filter(e => e.name === 'Haul').map(e => ({ id: e.id, errors: e.runtimeErrors.map(x => x.message).concat(e.manifestErrors.map(x => x.message)) }))))`, awaitPromise: true, returnByValue: true });
  const [haul] = JSON.parse(info.result.result.value);
  if (!haul) throw new Error('the Haul extension did not load');
  if (haul.errors.length) throw new Error('extension errors: ' + haul.errors.join('; '));
  console.log('extension id', haul.id);
  await extensionsPage.send('Page.navigate', { url: `chrome-extension://${haul.id}/popup.html` });
  await sleep(1500);
  const ask = async (message) => {
    const r = await extensionsPage.send('Runtime.evaluate', { expression: `chrome.runtime.sendMessage(${JSON.stringify(message)}).then(x => JSON.stringify(x))`, awaitPromise: true, returnByValue: true });
    if (r.result.exceptionDetails) throw new Error(r.result.exceptionDetails.exception.description);
    return JSON.parse(r.result.result.value);
  };
  const status = await ask({ type: 'status' });
  console.log('status', JSON.stringify(status));
  if (!status.connected) throw new Error('Haul is not answering on 48512');
  // Pair: the app shows an alert; press Allow for it.
  const approver = (async () => { for (let i = 0; i < 20; i++) { await sleep(500); if (await osa('tell application "System Events" to tell process "Haul"\nset clicked to false\nrepeat with w in windows\nif exists button "Allow" of w then\nclick button "Allow" of w\nset clicked to true\nend if\nend repeat\nif not clicked then error "no alert"\nend tell') !== null) return true; } return false; })();
  const paired = await ask({ type: 'pair' });
  console.log('pair', JSON.stringify(paired), 'approver clicked:', await approver);
  if (!paired.ok) throw new Error('pairing failed');
  await sleep(1000);
  // The same tab now shows the test page; the content script runs in it.
  await extensionsPage.send('Page.navigate', { url: pageURL });
  await sleep(2000);
  const run = async (expression) => {
    const r = await extensionsPage.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.result.exceptionDetails) throw new Error(r.result.exceptionDetails.exception.description);
    return r.result.result.value;
  };
  const clicked = await run(`(() => { const a = document.getElementById('file'); a.click(); return a.href; })()`);
  console.log('clicked', clicked);
  // Haul asks before starting: the catch panel is key; Return starts it.
  await sleep(2500);
  await osa('tell application "Haul" to activate');
  await sleep(300);
  await osa('tell application "System Events" to keystroke return');
  const file = join(homedir(), 'Downloads', expectedName);
  let done = false;
  for (let i = 0; i < 120; i++) { await sleep(500); if (existsSync(file)) { done = true; break; } }
  if (!done) throw new Error(`${file} never appeared`);
  console.log('downloaded', file, statSync(file).size, 'bytes');
  const stillOnPage = await run('location.href');
  if (stillOnPage !== pageURL) throw new Error(`the page navigated away to ${stillOnPage}; the click was not caught`);
  extensionsPage.close();
  console.log('PASS');
} catch (error) {
  failed = true;
  console.error('FAIL', error.message);
} finally {
  chrome.kill();
  await sleep(500);
  rmSync(profile, { recursive: true, force: true });
}
process.exit(failed ? 1 : 0);
