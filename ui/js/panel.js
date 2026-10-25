// The notice page: shown in place of a dashboard that is locked, failed, broken, not added, or when none are found.
import * as bridge from './bridge.js';

const ICON = {
  lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="5" y="10.5" width="14" height="10" rx="2"/><path d="M8.5 10.5V7.5a3.5 3.5 0 0 1 7 0v3"/></svg>',
  warn: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M12 3.5 21.5 20h-19z"/><path d="M12 10v4.5M12 17.2v.3" stroke-linecap="round"/></svg>',
  plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="3.5" y="3.5" width="17" height="17" rx="4"/><path d="M12 8v8M8 12h8"/></svg>',
  download: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11M7.5 10.5 12 15l4.5-4.5"/><path d="M4.5 16.5v2a2 2 0 0 0 2 2h11a2 2 0 0 0 2-2v-2"/></svg>',
  folder: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M3.5 6.5a2 2 0 0 1 2-2h4l2 2.5h7a2 2 0 0 1 2 2v8.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/></svg>',
};

const root = document.getElementById('card');
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

function head(icon, tone, title) {
  return `<div class="card-head"><span class="card-icon ${tone}">${ICON[icon]}</span><h1>${esc(title)}</h1></div>`;
}

function render(n) {
  if (!n) { root.innerHTML = ''; return; }
  const name = n.title || n.name || 'This dashboard';
  let h = '';
  switch (n.kind) {
    case 'locked':
      h = head('lock', 'info', `${name} is open in its own window`) +
        `<p>A dashboard can only run in one place at a time. Switch to its window, or close it and try again here.</p>
         <div class="actions"><button class="btn primary" data-act="switch">Switch to it</button><button class="btn" data-act="retry">Try again</button></div>
         <p class="note" id="note" hidden></p>`;
      break;
    case 'missing':
      h = head('warn', 'warn', `${n.name}'s folder was removed`) +
        `<p>${esc(name)} is still loaded, but its files are gone from:<span class="path">${esc(n.folder)}</span></p>
         <p>It is paused, because syncing, updating or reloading it would fail. If you moved the folder back, reload it. Otherwise close it.</p>
         <div class="actions"><button class="btn primary" data-act="reload">Reload ${esc(n.name)}</button><button class="btn" data-act="close">Close ${esc(n.name)}</button></div>
         <p class="note" id="note" hidden></p>`;
      break;
    case 'error':
      h = head('warn', 'warn', `${name} couldn't start`) +
        (n.message ? `<pre>${esc(n.message)}</pre>` : '') +
        `<p>It still works on its own from its folder. If this keeps happening, check that it is up to date.</p>
         <div class="actions"><button class="btn primary" data-act="retry">Try again</button></div>`;
      break;
    case 'broken':
      h = head('warn', 'warn', `${n.name || 'This folder'} has a problem with its dash.json`) +
        `<pre>${esc(n.message)}</pre>
         <p>Folder:<span class="path">${esc(n.folder)}</span></p>
         <p class="note">Nothing from this folder was loaded. Fix dash.json and restart DashLauncher.</p>`;
      break;
    case 'available': {
      const when = n.publishedAt ? new Date(n.publishedAt).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : '';
      const rel = n.version ? `Latest release <strong>v${esc(n.version)}</strong>${when ? `, published ${esc(when)}` : ''}.` : 'Its latest release is on GitHub.';
      h = head('download', 'info', `Get ${name}`) +
        `<p>${esc(name)} isn't installed yet. ${rel}</p>
         <ol class="steps">
           <li><button class="btn primary" data-act="download">${n.hasAsset ? `Download ${esc(n.assetName || 'the zip')}` : 'Open the release on GitHub'}</button></li>
           <li>Right-click the zip, choose <strong>Extract All</strong>, and extract it to:<span class="path">${esc(n.target)}</span>
             <button class="btn" data-act="folder">Open the modules folder</button></li>
           <li>Come back here and press <strong>Refresh</strong>. The ${esc(n.name)} tab turns from grey to colour, ready to use.
             <button class="btn" data-act="refresh">Refresh</button></li>
         </ol>
         <p class="note" id="note" hidden></p>
         ${n.hasAsset ? '<p class="note"><a href="#" data-act="page">See the release notes on GitHub</a></p>' : ''}
         ${n.source === 'manual' ? '<p class="note">Shown because it is enabled in catalog.json.</p>' : ''}`;
      break;
    }
    case 'declined':
      h = head('plus', '', `${name} isn't added`) +
        `<p>You chose not to add this dashboard. Its code runs inside DashLauncher once added, so only add dashboards from a source you trust.</p>
         <p>Version <strong>${esc(n.version)}</strong>, from:<span class="path">${esc(n.folder)}</span></p>
         <div class="actions"><button class="btn primary" data-act="approve">Add it</button></div>`;
      break;
    default: {
      h = head('folder', 'info', 'No dashboard modules yet') +
        `<p>Copy a dashboard module, like the NBADash folder, into DashLauncher's modules folder:<span class="path">${esc(n.modulesDir)}</span></p>
         <pre>DashLauncher\\
  modules\\
    NBADash\\      (has a dash.json)
    F1Dash\\</pre>
         <div class="actions"><button class="btn" data-act="folder">Open the modules folder</button><button class="btn primary" data-act="refresh">Refresh</button></div>
         <p class="note">DashLauncher also looks for modules every time it starts.</p>`;
    }
  }
  root.innerHTML = h;
  root.dataset.id = n.id || '';
  root.dataset.kind = n.kind || '';
}

root.addEventListener('click', async (e) => {
  const b = e.target.closest('[data-act]');
  if (!b) return;
  const id = root.dataset.id;
  e.preventDefault();
  const cmd = { reload: 'tab.reload', close: 'tab.close', retry: 'tab.retry', approve: 'tab.approve', switch: 'tab.switchTo', download: 'catalog.download', page: 'catalog.download', folder: 'modules.open', refresh: 'modules.scan' }[b.dataset.act];
  b.disabled = true;
  try {
    const args = b.dataset.act === 'page' ? { id, page: true } : { id };
    const ok = await bridge.request(cmd, args, cmd === 'modules.scan' ? 600000 : 30000);
    if (b.dataset.act === 'refresh' && ok && !ok.added && root.dataset.kind === 'available') {
      const note = document.getElementById('note');
      if (note) { note.hidden = false; note.textContent = 'Nothing new in the modules folder yet. Check that dash.json sits directly inside the extracted folder, then refresh again.'; }
    }
    if (b.dataset.act === 'reload' && ok === false) {
      const note = document.getElementById('note');
      if (note) { note.hidden = false; note.textContent = "Its dash.json still isn't there. Put the folder back where it was, then reload."; }
    }
    if (b.dataset.act === 'switch' && !ok) {
      const note = document.getElementById('note');
      if (note) { note.hidden = false; note.textContent = "Couldn't find its window. It may have just closed: try again."; }
    }
  } catch (err) { console.warn(err.message); }
  b.disabled = false;
});

bridge.on('notice', render);
bridge.on('theme', (d) => bridge.setTheme(d && d.theme));

(async () => {
  try {
    const r = await bridge.request('panel.get');
    bridge.setTheme(r.theme);
    render(r.notice);
  } catch (err) { console.warn(err.message); }
})();
