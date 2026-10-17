const api = globalThis.browser ?? globalThis.chrome;
api.storage.local.get({ port: 48512 }).then((s) => { document.getElementById('port').value = s.port; });
document.getElementById('save').addEventListener('click', async () => {
  const state = await api.runtime.sendMessage({ type: 'setPort', value: document.getElementById('port').value });
  document.getElementById('result').textContent = state && state.connected ? 'Downhaul found.' : 'Saved. Downhaul is not answering on that port yet.';
});
