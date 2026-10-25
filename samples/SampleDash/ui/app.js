// Sample Dash page: shows the dash contract working, with nothing fetched.
import * as bridge from './bridge.js';

const $ = (id) => document.getElementById(id);
let state = null;
let standaloneTheme = 'system';

const log = [];
function addLog(text) {
  const t = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  log.unshift({ t, text });
  log.length = Math.min(log.length, 8);
  $('log').innerHTML = log.map((l) => `<li><time>${l.t}</time><span>${l.text}</span></li>`).join('');
}

function render() {
  if (!state) return;
  const inLauncher = state.mode === 'launcher';
  $('where').textContent = inLauncher ? `inside DashLauncher v${state.launcherVersion}` : 'running on its own';
  $('btn-theme').hidden = inLauncher;                      // in the launcher, the launcher owns the theme
  $('halted').hidden = !state.halted;
  $('ticks').textContent = state.ticks;
  $('traffic').textContent = `${state.traffic.requests} simulated requests, ${(state.traffic.bytes / 1024).toFixed(1)} KB (nothing leaves this computer)`;
  $('live').textContent = state.live;
  $('t-update').checked = state.update;
  $('t-problem').checked = state.problem;
  const s = state.sync || { running: false, pct: 0 };
  $('bar-fill').style.width = `${s.running ? s.pct : (s.pct >= 100 ? 100 : 0)}%`;
  $('btn-sync').disabled = s.running || state.halted;
  $('btn-cancel').hidden = !s.running;
}

async function set(key, value) {
  try { state = await bridge.request('sample.set', { key, value }); render(); } catch (e) { addLog(e.message); }
}

document.querySelectorAll('[data-live]').forEach((b) => b.addEventListener('click', () => set('live', state.live + Number(b.dataset.live))));
$('t-update').addEventListener('change', (e) => set('update', e.target.checked));
$('t-problem').addEventListener('change', (e) => set('problem', e.target.checked));
$('btn-sync').addEventListener('click', async () => {
  try { if (await bridge.request('sync.run')) { state.sync = { running: true, pct: 0 }; render(); } } catch (e) { addLog(e.message); }
});
$('btn-cancel').addEventListener('click', async () => {
  try { await bridge.request('sync.cancel'); state.sync = { running: false, pct: 0 }; render(); addLog('fake sync cancelled'); } catch (e) { addLog(e.message); }
});
$('btn-resume').addEventListener('click', async () => {
  try { state = await bridge.request('traffic.resume'); render(); addLog('resumed'); } catch (e) { addLog(e.message); }
});
$('btn-theme').addEventListener('click', () => {
  standaloneTheme = { system: 'light', light: 'dark', dark: 'system' }[standaloneTheme];
  try { localStorage.setItem('theme', standaloneTheme); } catch { }
  bridge.setTheme(standaloneTheme);
  $('btn-theme').textContent = `Theme: ${standaloneTheme}`;
});

bridge.on('tick', (d) => { if (state) { state.ticks = d.ticks; state.traffic = d.traffic; render(); } });
bridge.on('sync', (d) => {
  if (!state) return;
  state.sync = d; render();
  if (!d.running && d.pct >= 100) addLog('fake sync finished');
});
bridge.on('traffic', (d) => { if (state && d.stopped) { state.halted = true; state.sync = { running: false, pct: 0 }; render(); addLog('traffic: stopped by the launcher'); } });
bridge.on('host.theme', (d) => { bridge.setTheme(d.theme); addLog(`host.theme: ${d.theme}`); });
bridge.on('host.visible', () => addLog('host.visible: tab shown'));
bridge.on('host.hidden', () => addLog('host.hidden: tab hidden'));

(async () => {
  try { standaloneTheme = localStorage.getItem('theme') || 'system'; } catch { }
  try {
    state = await bridge.request('init');
    if (state.mode !== 'launcher') { bridge.setTheme(standaloneTheme); $('btn-theme').textContent = `Theme: ${standaloneTheme}`; }
    else if (state.theme) bridge.setTheme(state.theme);
    render();
    $('log').innerHTML = '<li class="empty">Switch tabs or change the launcher theme to see messages here.</li>';
  } catch (e) {
    $('where').textContent = e.message;
  }
})();
