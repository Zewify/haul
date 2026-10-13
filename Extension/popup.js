const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);

async function currentTab() {
  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function render() {
  const tab = await currentTab();
  const state = await api.runtime.sendMessage({ type: 'status', tabId: tab && tab.id });
  $('connect').hidden = true; $('down').hidden = true; $('ready').hidden = true;
  const dot = $('dot');
  dot.className = 'dot';
  if (!state || !state.connected) {
    $('state').textContent = 'not running';
    $('down').hidden = false;
    $('portHint').textContent = `Looking on port ${state ? state.port : 48512}.`;
    return;
  }
  if (!state.paired) {
    $('state').textContent = 'not connected';
    dot.classList.add('warn');
    $('connect').hidden = false;
    return;
  }
  $('state').textContent = state.capture ? 'connected' : 'paused';
  dot.classList.add('on');
  $('ready').hidden = false;
  $('capture').checked = !!state.capture;
  $('mediaSection').hidden = !state.media;
  if (state.media) {
    const items = state.items || [];
    const fromPage = items.filter((i) => i.label);
    const seen = items.filter((i) => !i.label).slice().reverse();
    $('noMedia').hidden = items.length > 0;
    $('pageGroup').hidden = fromPage.length === 0;
    $('seenGroup').hidden = seen.length === 0;
    fill($('pageMedia'), fromPage, tab);
    fill($('media'), seen, tab);
  }
}

function fill(list, items, tab) {
  list.textContent = '';
  for (const item of items) {
    const li = document.createElement('li');
    const text = document.createElement('div');
    text.className = 'text';
    const { title, subtitle } = HaulMedia.describeMedia(item);
    const titleEl = document.createElement('span');
    titleEl.className = 'title';
    titleEl.textContent = title;
    const subtitleEl = document.createElement('span');
    subtitleEl.className = 'subtitle';
    subtitleEl.textContent = subtitle;
    text.append(titleEl, subtitleEl);
    text.title = item.url;
    const button = document.createElement('button');
    button.textContent = 'Grab';
    button.addEventListener('click', async () => {
      button.disabled = true;
      const result = await api.runtime.sendMessage({ type: 'grab', item, referrer: tab.url, pageTitle: tab.title });
      button.textContent = result && result.ok ? 'Sent' : (result && result.error) || 'Failed';
    });
    li.append(text, button);
    list.append(li);
  }
}

$('pairButton').addEventListener('click', async () => {
  $('pairButton').disabled = true;
  $('pairButton').textContent = 'Waiting for Haul…';
  const result = await api.runtime.sendMessage({ type: 'pair' });
  if (!result || !result.ok) {
    $('pairError').hidden = false;
    $('pairError').textContent = (result && result.error) || 'Could not connect';
    $('pairButton').disabled = false;
    $('pairButton').textContent = 'Connect to Haul';
  }
  await render();
});
$('capture').addEventListener('change', async (event) => {
  await api.runtime.sendMessage({ type: 'setCapture', value: event.target.checked });
  await render();
});
$('options').addEventListener('click', (event) => { event.preventDefault(); api.runtime.openOptionsPage(); });
$('disconnect').addEventListener('click', async (event) => { event.preventDefault(); await api.runtime.sendMessage({ type: 'disconnect' }); await render(); });
render();
