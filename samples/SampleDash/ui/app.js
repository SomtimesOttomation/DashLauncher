// Sample Dash page: the starting point for a new dash, built like NBADash and NHLDash with a made-up league.
// Data arrives as {event:'data', data:{key, ok, at, body}} after a 'data.get' request. The page only names keys;
// the backend decides where they come from (here: pretend servers that never touch the network).
import * as bridge from './bridge.js';

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

let state = null;                 // snapshot from the backend
let standaloneTheme = 'system';
const store = new Map();          // key -> { body, at, error, loading }
let routeKeys = [];               // keys the current view needs (Refresh refetches these)

// ------------------------------------------------------------------ data
// The failed-request rule: a key that failed is NOT asked for again on the next redraw. It waits until the person
// presses Refresh (F5), which calls want(key, true). Without this, a broken source is hammered on every render.
async function want(key, force = false) {
  const cur = store.get(key) || {};
  if (!force && (cur.body !== undefined || cur.loading || cur.error)) return;
  store.set(key, { ...cur, loading: true, error: null });
  try { await bridge.request('data.get', { key, force }); }
  catch (e) { store.set(key, { ...store.get(key), loading: false, error: e.message }); render(); }
}
const get = (key) => store.get(key)?.body;

bridge.on('data', (d) => {
  const cur = store.get(d.key) || {};
  if (d.ok) store.set(d.key, { body: d.body, at: new Date(d.at), loading: false, error: null });
  else store.set(d.key, { ...cur, loading: false, error: d.error });
  render();
});

// ------------------------------------------------------------------ the made-up league
// A real dash takes names and colours from its data source and caches team logos on disk the first time they show
// (NHLDash: one download per logo, kept 30 days). The Sample draws its logos here, so nothing is downloaded.
const TEAMS = {
  AUR: ['Aurora Comets', '0f766e'], BAY: ['Bayside Herons', '1d4ed8'], CED: ['Cedar Falls Lynx', '15803d'], DUN: ['Dunmore Pilots', 'b45309'],
  EMB: ['Ember City Flames', 'dc2626'], FOX: ['Foxhollow Rangers', 'ea580c'], GLA: ['Glacier Bay Owls', '0284c7'], HAR: ['Harbor Point Mariners', '1e3a8a'],
  IRO: ['Ironvale Hammers', '4b5563'], JUN: ['Juniper Ridge Elk', '65a30d'], KES: ['Kestrel Bay Hawks', '7c3aed'], LAN: ['Lantern Hill Sparks', 'ca8a04'],
};
const teamName = (k) => TEAMS[k]?.[0] || k;
const teamColor = (k) => `#${TEAMS[k]?.[1] || '6b7280'}`;
function logo(k, cls = 'slogo') {
  const c = teamColor(k);
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><path d="M32 4 56 12v20c0 14-10 23-24 28C18 55 8 46 8 32V12z" fill="${c}"/><path d="M32 10 50 16v16c0 10-7 17-18 21-11-4-18-11-18-21V16z" fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="2"/><text x="32" y="39" font-family="Segoe UI,Arial" font-size="15" font-weight="700" fill="#fff" text-anchor="middle">${k}</text></svg>`;
  return `<img class="${cls}" alt="" src="data:image/svg+xml,${encodeURIComponent(svg)}">`;
}

// ------------------------------------------------------------------ helpers
function today() { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; }
function shiftDate(iso, days) { const d = new Date(iso + 'T12:00:00'); d.setDate(d.getDate() + days); return d.toISOString().slice(0, 10); }
function niceDate(iso) { return new Date(iso + 'T12:00:00').toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' }); }
function ago(at) {
  if (!at) return '';
  const s = Math.max(0, Math.round((Date.now() - at) / 1000));
  if (s < 60) return 'just now';
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  return `${Math.round(s / 3600)}h ago`;
}
const favs = () => new Set(state?.settings?.favorites || []);
const isLive = (g) => g.state === 'LIVE';
const isFinal = (g) => g.state === 'FINAL';
const liveCount = () => (get(`score:${today()}`)?.games || []).filter(isLive).length;
function gameStatus(g) {
  if (isLive(g)) return g.clock;
  if (isFinal(g)) return g.ot ? 'Final/OT' : 'Final';
  return new Date(g.start).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}
function status(key) {
  const s = store.get(key);
  if (!s) return '';
  if (s.error && s.body === undefined) return `<div class="note err">Could not load: ${esc(s.error)} Press Refresh (F5) to try again.</div>`;
  if (s.body === undefined) return '<div class="note">Loading...</div>';
  return '';
}
function record(k) {
  const t = (get('standings')?.teams || []).find((x) => x.code === k);
  return t ? `${t.w}-${t.l}-${t.otl}` : '';
}

// ------------------------------------------------------------------ views
const views = {};

// Game cards: NBADash's layout (68 px logos, code over name and record, 26 px score, dimmed loser, gold edge for favourites).
function gameCard(g) {
  const fav = favs();
  const live = isLive(g), fut = g.state === 'FUT';
  const row = (t, other) => {
    const win = isFinal(g) && t.score > other.score, lose = isFinal(g) && t.score < other.score;
    const sub = [teamName(t.code), record(t.code)].filter(Boolean).join(' · ');
    return `<div class="gteam${win ? ' win' : ''}${lose ? ' lose' : ''}${fav.has(t.code) ? ' fav' : ''}"><span class="gside">${logo(t.code, 'glogo')}<span class="gnames"><b>${esc(t.code)}</b><small class="muted">${esc(sub)}</small></span></span>${fut ? '' : `<span class="gsc"><b class="sc">${t.score ?? 0}</b><small class="muted">${t.shots != null ? t.shots + ' SOG' : ''}</small></span>`}</div>`;
  };
  return `<a class="card game${live ? ' live' : ''}${fav.has(g.away.code) || fav.has(g.home.code) ? ' fav' : ''}" href="#/team/${g.home.code}">
    <div class="gstat${live ? ' on' : ''}">${live ? 'LIVE ' : ''}${esc(gameStatus(g))}</div>${row(g.away, g.home)}${row(g.home, g.away)}
    <div class="gmeta"><span>${esc(g.venue)}</span><span>${esc(new Date(g.start).toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' }))}</span></div></a>`;
}

views.scores = (date) => {
  date = date || today();
  const key = `score:${date}`;
  routeKeys = [key, 'standings'];
  want(key); want('standings');
  const sc = get(key);
  const fav = favs();
  const games = (sc?.games || []).slice().sort((a, b) => (isLive(b) - isLive(a)) || ((fav.has(b.away.code) || fav.has(b.home.code)) - (fav.has(a.away.code) || fav.has(a.home.code))) || a.start.localeCompare(b.start));
  return `<div class="datebar">
      <a class="btn sq" href="#/scores/${shiftDate(date, -1)}" aria-label="Previous day">&lsaquo;</a>
      <strong>${esc(niceDate(date))}</strong>
      <a class="btn sq" href="#/scores/${shiftDate(date, 1)}" aria-label="Next day">&rsaquo;</a>
      ${date !== today() ? '<a class="btn" href="#/">Today</a>' : ''}
    </div>
    ${status(key)}
    ${sc && !games.length ? '<div class="note">No games on this day.</div>' : ''}
    <div class="grid games">${games.map(gameCard).join('')}</div>`;
};

views.standings = () => {
  routeKeys = ['standings'];
  want('standings');
  const st = get('standings');
  if (!st) return status('standings');
  const fav = favs();
  return `<div class="segs bar1"><span class="muted small">Updated ${esc(ago(store.get('standings')?.at))}</span></div>
    <section class="card wide"><h2>League</h2><div class="tscroll"><table class="tbl">
      <thead><tr><th></th><th class="l">Team</th><th>GP</th><th>W</th><th>L</th><th>OTL</th><th>PTS</th><th>P%</th><th>GF</th><th>GA</th><th>DIFF</th><th>L10</th></tr></thead><tbody>
      ${st.teams.map((t, i) => `<tr class="${fav.has(t.code) ? 'fav' : ''}"><td>${i + 1}</td><td class="l"><a class="tlink" href="#/team/${t.code}">${logo(t.code)} ${esc(teamName(t.code))}</a></td><td>${t.gp}</td><td>${t.w}</td><td>${t.l}</td><td>${t.otl}</td><td><b>${t.pts}</b></td><td>${t.gp ? (t.pts / (2 * t.gp)).toFixed(3).replace(/^0/, '') : '-'}</td><td>${t.gf}</td><td>${t.ga}</td><td>${t.gf - t.ga > 0 ? '+' : ''}${t.gf - t.ga}</td><td>${esc(t.l10)}</td></tr>`).join('')}
    </tbody></table></div></section>`;
};

views.team = (k) => {
  const key = `team:${k}`;
  routeKeys = [key, 'standings'];
  want(key); want('standings');
  const t = get(key);
  const st = (get('standings')?.teams || []).find((x) => x.code === k);
  const fav = favs().has(k);
  const head = `<section class="card thead" style="--tc:${teamColor(k)}">${logo(k, 'blogo')}<div><h2 class="big2">${esc(teamName(k))}</h2>
      <div class="trec">${st ? `<b>${st.w}-${st.l}-${st.otl}</b>, ${st.pts} points, last 10: ${esc(st.l10)}` : ''}</div></div>
      <button class="star big${fav ? ' on' : ''}" type="button" data-star="${k}" title="${fav ? 'Remove from favourites' : 'Add to favourites'}" aria-pressed="${fav}">${fav ? '★' : '☆'}</button></section>`;
  if (!t) return head + status(key);
  const kp = st ? `<div class="kpis"><div><b>${st.gp ? (st.pts / (2 * st.gp)).toFixed(3).replace(/^0/, '') : '-'}</b><small>P%</small></div><div><b>${(st.gf / Math.max(1, st.gp)).toFixed(2)}</b><small>GF/GP</small></div><div><b>${(st.ga / Math.max(1, st.gp)).toFixed(2)}</b><small>GA/GP</small></div><div><b>${esc(st.l10)}</b><small>L10</small></div></div>` : '';
  return head + `<section class="card wide"><h2>Season</h2>${kp}</section>
    <section class="card wide"><h2>Players</h2><div class="tscroll"><table class="tbl"><thead><tr><th class="l">Player</th><th>Pos</th><th>GP</th><th>G</th><th>A</th><th>P</th><th>+/-</th><th>SOG</th></tr></thead><tbody>
      ${t.players.map((p) => `<tr><td class="l">${esc(p.name)}</td><td>${p.pos}</td><td>${p.gp}</td><td>${p.g}</td><td>${p.a}</td><td><b>${p.pts}</b></td><td>${p.pm > 0 ? '+' : ''}${p.pm}</td><td>${p.sog}</td></tr>`).join('')}
    </tbody></table></div></section>`;
};

// ------------------------------------------------------------------ settings, Sample tools and host messages
const hostLog = [];
function addLog(text) {
  const t = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  hostLog.unshift({ t, text }); hostLog.length = Math.min(hostLog.length, 8);
  if (parseRoute().view === 'settings') render();
}
views.settings = () => {
  routeKeys = [];
  const s = state.settings, t = state.traffic, p = state.pretend;
  return `<div class="grid two">
    <section class="card"><h2>Favourite teams</h2><p class="muted">Click the star on a team in the banner (or on its team page). Favourites sit at the front of the banner, their games show first and their rows are highlighted.</p><p>${(s.favorites || []).length ? s.favorites.map((k) => `<a class="favchip" href="#/team/${k}">${logo(k)} ${esc(teamName(k))}</a>`).join(' ') : '<span class="muted">None yet.</span>'}</p></section>
    <section class="card"><h2>Automatic refresh</h2>
      <p class="muted">Off: the dash only fetches when you open a page or press Refresh (F5). On: while this tab is visible, today's scores are refetched on a timer.</p>
      <label class="row"><span>Refresh automatically</span><input id="set-auto" type="checkbox"${s.autoRefresh ? ' checked' : ''}></label>
      <label class="row"><span>Every</span><span><input id="set-secs" type="number" min="20" max="600" step="10" value="${s.refreshSeconds}"> seconds</span></label></section>
    <section class="card"><h2>Updates</h2><p class="muted">Click the version number to check GitHub for a newer release. Not affected by the pause switch. Off by default in the Sample, so it contacts nothing; a real dash turns it on.</p>
      <label class="row"><span>Check for updates on start</span><input id="set-upd" type="checkbox"${s.updateCheck ? ' checked' : ''}></label></section>
    <section class="card"><h2>Data and sources</h2>
      <p class="small">Pretend servers (scores.sample.invalid, teams.sample.invalid). A real dash lists each source here with a link to its terms, as in dash.json.</p>
      <p class="muted small">This session: ${t.requests} requests, ${(t.bytes / 1024).toFixed(1)} KB, ${t.errors} errors.</p>
      <div class="actions"><button id="set-clear" class="btn" type="button">Clear saved data</button><a class="btn" href="#/traffic">Traffic details</a></div></section>
    <section class="card"><h2>Sample tools</h2><p class="muted">Pretend states to try the launcher's tab badges, and failing downloads to try the failed-request rule. Not saved.</p>
      <div class="row"><span>Pretend live games</span><span class="stepper"><button class="btn sq" type="button" data-live="-1" aria-label="Fewer">&minus;</button><b>${p.live}</b><button class="btn sq" type="button" data-live="1" aria-label="More">+</button></span></div>
      <label class="row"><span>Pretend an update is available</span><input id="t-update" type="checkbox"${p.update ? ' checked' : ''}></label>
      <label class="row"><span>Pretend there is a problem</span><input id="t-problem" type="checkbox"${p.problem ? ' checked' : ''}></label>
      <label class="row"><span>Pretend downloads fail</span><input id="t-fail" type="checkbox"${p.fail ? ' checked' : ''}></label></section>
    <section class="card"><h2>Messages from the host</h2><ol class="log">${hostLog.length ? hostLog.map((l) => `<li><time>${l.t}</time><span>${esc(l.text)}</span></li>`).join('') : '<li class="muted">Switch tabs or change the launcher theme to see messages here.</li>'}</ol></section>
  </div>`;
};
function confirmDialog(title, html) {
  return new Promise((resolve) => {
    $('dialog-title').textContent = title; $('dialog-body').innerHTML = html; $('dialog').hidden = false; $('dialog-ok').focus();
    const done = (v) => { $('dialog').hidden = true; $('dialog-ok').onclick = $('dialog-cancel').onclick = null; resolve(v); };
    $('dialog-ok').onclick = () => done(true); $('dialog-cancel').onclick = () => done(false);
  });
}
async function setSetting(key, value, ack = false) {
  try { state = await bridge.request('settings.set', { key, value, ack }); } catch (e) { alertNote(e.message); }
  render();
}
async function setTool(key, value) {
  try { state = await bridge.request('sample.set', { key, value }); } catch (e) { alertNote(e.message); }
  render();
}
function alertNote(msg) { const n = document.createElement('div'); n.className = 'toast'; n.textContent = msg; document.body.append(n); setTimeout(() => n.remove(), 4000); }
document.addEventListener('change', async (e) => {
  const id = e.target.id;
  if (id === 'set-upd') setSetting('updateCheck', e.target.checked);
  if (id === 'set-secs') setSetting('refreshSeconds', Number(e.target.value));
  if (id === 't-update') setTool('update', e.target.checked);
  if (id === 't-problem') setTool('problem', e.target.checked);
  if (id === 't-fail') setTool('fail', e.target.checked);
  if (id === 'set-auto') {
    const on = e.target.checked;
    if (on && !state.settings.autoAck) {
      const ok = await confirmDialog('Turn on automatic refresh?', `<p>While this tab is visible, the dash will contact its data source on its own every ${state.settings.refreshSeconds} seconds for today's scores.</p><p class="muted">Keep the interval reasonable; it stops whenever you switch tabs or press the live status to pause.</p>`);
      if (!ok) { e.target.checked = false; return; }
      return setSetting('autoRefresh', true, true);
    }
    setSetting('autoRefresh', on);
  }
});
document.addEventListener('click', async (e) => {
  const lv = e.target.closest('[data-live]');
  if (lv) { setTool('live', state.pretend.live + Number(lv.dataset.live)); return; }
  if (e.target.id !== 'set-clear') return;
  try { await bridge.request('cache.clear'); store.clear(); loadSeason(); alertNote('Saved data cleared.'); } catch (err) { alertNote(err.message); }
});

// ------------------------------------------------------------------ team banner (same look and behaviour as NBADash)
let bannerSig = '';
function renderBanner(active) {
  const el = $('banner');
  const fav = favs();
  const sig = `${[...fav].join(',')}|${active}`;
  if (sig === bannerSig && el.firstChild) return;
  bannerSig = sig;
  const prev = el.querySelector('.banner-strip')?.scrollLeft || 0;
  const byName = (a, b) => teamName(a).localeCompare(teamName(b));
  const all = Object.keys(TEAMS);
  const f = [...fav].filter((k) => TEAMS[k]).sort(byName), rest = all.filter((k) => !fav.has(k)).sort(byName);
  const tile = (k) => `<a class="tile${fav.has(k) ? ' fav' : ''}${k === active ? ' active' : ''}" href="#/team/${k}" role="listitem" title="${esc(teamName(k))}" style="--tc:${teamColor(k)}">
      <button class="star tile-star${fav.has(k) ? ' on' : ''}" type="button" data-star="${k}" title="${fav.has(k) ? 'Remove from favourites' : 'Add to favourites'}" aria-pressed="${fav.has(k)}">${fav.has(k) ? '★' : '☆'}</button>
      ${logo(k, 'tile-logo')}<span class="tile-code">${k}</span></a>`;
  el.innerHTML = `<button class="banner-btn left" type="button" aria-label="Scroll teams left">‹</button>
    <div class="banner-strip" role="list">${f.map(tile).join('')}${f.length ? '<span class="banner-divider" aria-hidden="true"></span>' : ''}${rest.map(tile).join('')}</div>
    <button class="banner-btn right" type="button" aria-label="Scroll teams right">›</button>`;
  const strip = el.querySelector('.banner-strip'), left = el.querySelector('.banner-btn.left'), right = el.querySelector('.banner-btn.right');
  const scroll = (dir) => strip.scrollBy({ left: dir * Math.max(300, strip.clientWidth * 0.8), behavior: 'smooth' });
  left.onclick = () => scroll(-1); right.onclick = () => scroll(1);
  strip.addEventListener('wheel', (e) => { if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) { strip.scrollLeft += e.deltaY; e.preventDefault(); } }, { passive: false });
  const update = () => {
    left.classList.toggle('hide', strip.scrollLeft < 8);
    right.classList.toggle('hide', strip.scrollLeft + strip.clientWidth >= strip.scrollWidth - 8);
  };
  strip.addEventListener('scroll', update, { passive: true });
  strip.style.scrollBehavior = 'auto'; strip.scrollLeft = prev; strip.style.scrollBehavior = '';
  requestAnimationFrame(() => {
    const a = strip.querySelector('.tile.active');
    if (a && (a.offsetLeft < strip.scrollLeft || a.offsetLeft + a.offsetWidth > strip.scrollLeft + strip.clientWidth)) a.scrollIntoView({ inline: 'center', block: 'nearest' });
    update();
  });
}
// Several favourites: the star toggles one team in the list; the backend saves it.
document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-star]');
  if (!b) return;
  e.preventDefault(); e.stopPropagation();
  const k = b.dataset.star, list = [...(state.settings.favorites || [])];
  const i = list.indexOf(k);
  if (i >= 0) list.splice(i, 1); else list.push(k);
  state.settings.favorites = list;          // show it right away
  setSetting('favorites', list);
}, true);

// ------------------------------------------------------------------ season: saved weeks, week bar, sync
const season = { weeks: [], loaded: false, sync: null };   // weeks: [{ monday, cached }]
async function loadSeason() {
  try { season.weeks = await bridge.request('season.weeks'); } catch { season.weeks = []; }
  season.loaded = true;
  for (const w of season.weeks) if (w.cached && get(`week:${w.monday}`) === undefined) bridge.request('data.get', { key: `week:${w.monday}`, cacheOnly: true }).catch(() => {});
  render();
}
function weekList() {
  const list = []; let n = 0;
  for (const w of season.weeks) {
    const b = get(`week:${w.monday}`);
    if (!b) continue;
    n++; list.push({ n, monday: w.monday });
  }
  return list;
}
function weekRange(monday) {
  const a = new Date(monday + 'T12:00:00'), b = new Date(a); b.setDate(b.getDate() + 6);
  const f = (d) => d.toLocaleDateString([], { month: 'short', day: 'numeric' });
  return `${f(a)} - ${f(b)}`;
}
// Week bar: full width under the banner, left aligned, NBADash styles. Only saved weeks are links.
function renderWeekBar(activeN) {
  const weeks = weekList();
  const s = season.sync;
  $('weekbar').innerHTML = `<span class="weekbar-label">Season</span>
    <button class="btn small-btn" type="button" id="btn-sync"${s?.running || state.halted ? ' disabled' : ''}>${s?.running ? `Syncing ${s.pct}%` : weeks.length ? 'Sync season' : 'Sync the season'}</button>
    ${weeks.map((w) => `<a class="weeklink${w.n === activeN ? ' active' : ''}" href="#/week/${w.n}" title="${esc(weekRange(w.monday))}">Week ${w.n}</a>`).join('')}
    ${!weeks.length && season.loaded ? '<span class="muted small">Sync once to unlock the week pages.</span>' : ''}`;
}
const syncAck = () => { try { return localStorage.getItem('syncAck') === '1'; } catch { return false; } };
async function runSync() {
  const todo = season.weeks.filter((w) => !w.cached).length + 2;
  if (!syncAck()) {
    const ok = await confirmDialog('Sync the season?', `<p>The dash will download the season one week at a time, about ${todo} requests now. Weeks already saved are not downloaded again, so later syncs are only a few requests.</p><p class="muted">It runs in the background, keeps going if you switch tabs, and the pause switch stops it.</p>`);
    if (!ok) return;
    try { localStorage.setItem('syncAck', '1'); } catch { }
  }
  try { const r = await bridge.request('sync.run'); if (r && r.started) { season.sync = { running: true, pct: 0 }; render(); } }
  catch (e) { alertNote(e.message); }
}
document.addEventListener('click', (e) => { if (e.target.id === 'btn-sync') runSync(); });
bridge.on('sync', async (d) => {
  season.sync = d;
  if (!d.running) {
    season.sync = null;
    if (!d.cancelled) { alertNote('Season sync finished.'); await loadSeason(); return; }
  }
  render();
});
views.week = (n) => {
  n = Number(n);
  const w = weekList().find((x) => x.n === n);
  routeKeys = w ? [`week:${w.monday}`] : [];
  if (!w) return '<div class="note">That week is not saved yet. Press <b>Sync season</b> in the bar above.</div>';
  const days = (get(`week:${w.monday}`).days || []).filter((d) => d.games.length);
  const rec = {};
  for (const d of days) for (const g of d.games) {
    if (!isFinal(g)) continue;
    for (const [me, op] of [[g.away, g.home], [g.home, g.away]]) {
      const r = (rec[me.code] ||= { w: 0, l: 0, o: 0, gf: 0, ga: 0 });
      r.gf += me.score; r.ga += op.score;
      if (me.score > op.score) r.w++; else if (g.ot) r.o++; else r.l++;
    }
  }
  const table = Object.entries(rec).sort((a, b) => (b[1].w * 2 + b[1].o) - (a[1].w * 2 + a[1].o) || (b[1].gf - b[1].ga) - (a[1].gf - a[1].ga));
  const line = (g) => {
    const fin = isFinal(g), aw = fin && g.away.score > g.home.score;
    return `<a class="sline" href="#/team/${g.home.code}">${logo(g.away.code)}<span class="${fin && aw ? 'b' : ''}">${esc(g.away.code)} ${fin ? g.away.score : ''}</span><span class="muted">@</span>${logo(g.home.code)}<span class="${fin && !aw ? 'b' : ''}">${esc(g.home.code)} ${fin ? g.home.score : ''}</span><span class="sres muted">${esc(gameStatus(g))}</span></a>`;
  };
  return `<div class="datebar"><a class="btn sq" href="#/week/${n - 1}" aria-label="Previous week"${n <= 1 ? ' hidden' : ''}>&lsaquo;</a><strong>Week ${n} &middot; ${esc(weekRange(w.monday))}</strong><a class="btn sq" href="#/week/${n + 1}" aria-label="Next week"${weekList().some((x) => x.n === n + 1) ? '' : ' hidden'}>&rsaquo;</a></div>
    <div class="grid two"><section class="card"><h2>Games</h2>${days.map((d) => `<h3 class="sub">${esc(niceDate(d.date))}</h3>${d.games.map(line).join('')}`).join('') || '<p class="muted">No games.</p>'}</section>
      <section class="card"><h2>Team records this week</h2>${table.length ? `<table class="tbl"><thead><tr><th class="l">Team</th><th>W</th><th>L</th><th>OTL</th><th>GF</th><th>GA</th></tr></thead><tbody>${table.map(([k, r]) => `<tr class="${favs().has(k) ? 'fav' : ''}"><td class="l"><a class="tlink" href="#/team/${k}">${logo(k)} ${esc(teamName(k))}</a></td><td>${r.w}</td><td>${r.l}</td><td>${r.o}</td><td>${r.gf}</td><td>${r.ga}</td></tr>`).join('')}</tbody></table>` : '<p class="muted">No finished games yet.</p>'}</section></div>`;
};

// ------------------------------------------------------------------ traffic details (NBADash's hidden counter page)
let trafficData = null;
views.traffic = () => {
  routeKeys = [];
  bridge.request('traffic.get').then((t) => { const first = !trafficData; trafficData = t; if (first && parseRoute().view === 'traffic') render(); }).catch(() => {});
  const t = trafficData;
  if (!t) return '<div class="note">Loading...</div>';
  const kb = (b) => (b / 1024).toFixed(1) + ' KB';
  const up = `${Math.floor(t.uptimeSec / 3600)}h ${Math.floor((t.uptimeSec % 3600) / 60)}m`;
  const hosts = Object.entries(t.byHost || {});
  return `<section class="card wide"><h2>Data traffic this session</h2><div class="kpis"><div><b>${t.requests}</b><small>requests</small></div><div><b>${kb(t.bytes)}</b><small>downloaded</small></div><div><b>${t.errors}</b><small>errors</small></div><div><b>${up}</b><small>open for</small></div></div>
      <p class="muted small">Counted by the dash itself, the same numbers DashLauncher shows. Update checks to GitHub are not counted.</p></section>
    <section class="card wide"><h2>By server</h2>${hosts.length ? `<table class="tbl"><thead><tr><th class="l">Server</th><th>Requests</th><th>Downloaded</th><th>Errors</th></tr></thead><tbody>${hosts.map(([h, v]) => `<tr><td class="l">${esc(h)}</td><td>${v.requests}</td><td>${kb(v.bytes)}</td><td>${v.errors}</td></tr>`).join('')}</tbody></table>` : '<p class="muted">Nothing downloaded yet this session.</p>'}</section>
    <section class="card wide"><h2>Last requests</h2>${(t.last || []).length ? `<div class="tscroll"><table class="tbl"><thead><tr><th class="l">Time</th><th class="l">What</th><th class="l">Server</th><th>Size</th><th>Time taken</th><th>Result</th></tr></thead><tbody>${t.last.map((r) => `<tr><td class="l">${esc(new Date(r.at).toLocaleTimeString())}</td><td class="l">${esc(r.key)}</td><td class="l">${esc(r.host)}</td><td>${kb(r.bytes)}</td><td>${r.ms} ms</td><td>${r.ok ? 'OK' : '<span class="upd-err">failed</span>'}</td></tr>`).join('')}</tbody></table></div>` : '<p class="muted">None yet.</p>'}</section>`;
};

// ------------------------------------------------------------------ hover cards for stat terms
// Every abbreviation and calculated number explains itself: add the term to GLOSS and any table heading
// (or .kpis label) with exactly that text gets a dotted underline and a hover card. Formulas go in the text.
const GLOSS = {
  GP: 'Games played.',
  W: 'Wins.', L: 'Losses in regulation time.',
  OTL: 'Overtime and shootout losses (worth 1 point).',
  PTS: 'Points: 2 for a win, 1 for an overtime or shootout loss.',
  'P%': 'Points percentage: points earned / points possible (2 per game played).',
  GF: 'Goals for.', GA: 'Goals against.',
  DIFF: 'Goal difference: goals for minus goals against.',
  'GF/GP': 'Goals for per game played.', 'GA/GP': 'Goals against per game played.',
  L10: 'Record in the last 10 games (W-L-OTL).',
  G: 'Goals.', A: 'Assists.', P: 'Points: goals + assists.',
  '+/-': 'Plus/minus: goals for minus goals against while the player is on the ice.',
  SOG: 'Shots on goal: shots that reached the goalie or went in.',
};
function addGloss(root) {
  root.querySelectorAll('th, .kpis small').forEach((el) => {
    const key = el.textContent.trim();
    if (GLOSS[key]) { el.dataset.gloss = key; el.classList.add('hint'); }
  });
}
const tip = document.createElement('div'); tip.className = 'tipcard'; tip.hidden = true; document.body.append(tip);
document.addEventListener('mouseover', (e) => {
  const el = e.target.closest('[data-gloss]');
  if (!el) { tip.hidden = true; return; }
  tip.innerHTML = `<b>${esc(el.dataset.gloss)}</b><div>${esc(GLOSS[el.dataset.gloss])}</div>`;
  tip.hidden = false;
  const r = el.getBoundingClientRect();
  tip.style.left = `${Math.max(8, Math.min(window.innerWidth - 328, r.left + r.width / 2 - 160))}px`;
  tip.style.top = `${r.bottom + 8 + window.scrollY}px`;
});

// ------------------------------------------------------------------ updates (same window and steps as NBADash)
const upd = { phase: 'idle', info: null, pct: 0, text: '', error: '' };
const fmtDay = (iso) => { const d = new Date(iso); return isNaN(d) ? '' : d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }); };
const mbs = (n) => (n ? `${(n / 1048576).toFixed(1)} MB` : '');
function versionChip() {
  const b = $('btn-version');
  b.textContent = state.version ? `v${state.version}` : '';
  b.hidden = !state.version;
  b.classList.toggle('has-update', upd.phase === 'available' || upd.phase === 'staged');
  b.title = upd.phase === 'available' ? `Version ${upd.info?.latest} is available` : upd.phase === 'staged' ? 'Update downloaded: click to install' : 'Check for updates';
}
function notesHtml(text) {
  const lines = String(text || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return '<div class="muted">No release notes were published.</div>';
  return lines.map((t) => {
    const clean = esc(t.replace(/\*\*/g, ''));
    if (/^#{1,6}\s/.test(t) || /^\*\*.+\*\*$/.test(t)) return `<div class="upd-h">${clean.replace(/^#{1,6}\s+/, '')}</div>`;
    if (/^[-*]\s/.test(t)) return `<div class="upd-li">${clean.replace(/^[-*]\s+/, '')}</div>`;
    return `<div>${clean}</div>`;
  }).join('');
}
function paintUpdate() {
  versionChip();
  if ($('upd').hidden) return;
  const i = upd.info || {};
  const btn = (label, act, primary) => `<button class="btn${primary ? ' primary' : ''}" type="button" data-upd="${act}">${label}</button>`;
  const bar = `<div class="pbar"><i style="width:${upd.pct || 3}%"></i></div><small class="muted">${esc(upd.text)}</small>`;
  let body;
  switch (upd.phase) {
    case 'checking': body = bar + `<div class="actions end">${btn('Close', 'close')}</div>`; break;
    case 'current': body = `<p><b>You're up to date (v${esc(i.latest)}).</b></p><div class="actions end">${btn('Check again', 'check')}${btn('Done', 'close', 1)}</div>`; break;
    case 'ahead': body = `<p>This copy (v${esc(i.current)}) is newer than the latest published release (v${esc(i.latest)}).</p><div class="actions end">${btn('Done', 'close', 1)}</div>`; break;
    case 'none': body = `<p>No release has been published yet.</p><p class="muted small">While the repository is private, GitHub does not show its releases here. Updates then come as drop-in zips through DashLauncher.</p><div class="actions end">${btn('Done', 'close', 1)}</div>`; break;
    case 'available': body = `<p><b>Version ${esc(i.latest)} is available</b> <small class="muted">${[fmtDay(i.published), mbs(i.size)].filter(Boolean).join(' · ')}</small></p><div class="upd-notes">${notesHtml(i.notes)}</div>
        ${i.installable === false ? '<p class="muted">This release has no update package attached yet, so it cannot be installed from here. Try again later.</p>' : ''}
        <div class="actions end">${btn('Later', 'close')}${i.installable === false ? '' : btn('Download and install', 'stage', 1)}</div>`; break;
    case 'downloading': body = `<p><b>Downloading version ${esc(i.latest || '')}</b></p>${bar}<div class="actions end">${btn('Cancel', 'cancel')}</div>`; break;
    case 'staged': body = `<p><b>Version ${esc(i.latest)} is downloaded and verified.</b></p><p class="muted">The dashboard will close, swap in the new files and reopen. Your favourites, settings and saved data stay as they are. If the new version fails to start, the previous one is restored.</p><div class="actions end">${btn('Not now', 'close')}${btn('Restart now', 'apply', 1)}</div>`; break;
    case 'error': body = `<p class="upd-err">${esc(upd.error)}</p><div class="actions end">${btn('Close', 'close')}${btn('Try again', 'check', 1)}</div>`; break;
    default: body = `<div class="actions end">${btn('Check for updates', 'check', 1)}</div>`;
  }
  $('upd-box').innerHTML = `<h2>Updates</h2><p class="muted">You have v${esc(state.version || '?')}</p>${body}`;
}
async function checkUpdate(quiet = false) {
  if (upd.phase === 'checking' || upd.phase === 'downloading') return;
  upd.quiet = quiet; upd.phase = 'checking'; upd.error = ''; upd.pct = 0; upd.text = 'Asking GitHub for the latest release...'; paintUpdate();
  try { if ((await bridge.request('update.check')) === false) { upd.phase = upd.info?.status === 'available' ? 'available' : 'idle'; paintUpdate(); } }
  catch (e) { upd.phase = 'error'; upd.error = e.message; paintUpdate(); }
}
bridge.on('update', (d) => {
  if (d.running) { upd.pct = d.pct || 0; upd.text = d.text || ''; if (d.action === 'Stage') upd.phase = 'downloading'; }
  else {
    const r = d.result || {};
    upd.pct = 0; upd.text = '';
    if (r.status === 'error') { upd.phase = upd.quiet ? 'idle' : 'error'; upd.error = r.error || 'The update did not finish.'; }
    else { upd.phase = r.status || 'idle'; upd.info = r; }
    if (upd.quiet && upd.phase === 'available') alertNote(`Version ${r.latest} is available. Click the version number to update.`);
  }
  paintUpdate();
});
$('btn-version').addEventListener('click', () => {
  upd.quiet = false;
  $('upd').hidden = false;
  if (!['checking', 'downloading', 'available', 'staged'].includes(upd.phase)) checkUpdate(); else paintUpdate();
});
$('upd').addEventListener('click', async (e) => {
  if (e.target.id === 'upd') { $('upd').hidden = true; return; }
  const a = e.target.closest('[data-upd]')?.dataset.upd;
  if (!a) return;
  if (a === 'close') $('upd').hidden = true;
  if (a === 'check') checkUpdate();
  if (a === 'stage') { upd.quiet = false; upd.phase = 'downloading'; upd.pct = 0; upd.text = 'Starting...'; paintUpdate(); try { await bridge.request('update.stage'); } catch (err) { upd.phase = 'error'; upd.error = err.message; paintUpdate(); } }
  if (a === 'cancel') { try { await bridge.request('update.cancel'); } catch { } upd.phase = upd.info?.status === 'available' ? 'available' : 'idle'; paintUpdate(); }
  if (a === 'apply') { try { await bridge.request('update.apply'); } catch (err) { upd.phase = 'error'; upd.error = err.message; paintUpdate(); } }
});

// ------------------------------------------------------------------ routing and render
function parseRoute() {
  const h = location.hash || '#/';
  let m;
  if ((m = h.match(/^#\/week\/(\d{1,2})$/))) return { view: 'week', arg: m[1], tab: '' };
  if ((m = h.match(/^#\/team\/([A-Z]{3})$/)) && TEAMS[m[1]]) return { view: 'team', arg: m[1], tab: '' };
  if ((m = h.match(/^#\/scores\/(\d{4}-\d{2}-\d{2})$/))) return { view: 'scores', arg: m[1], tab: 'scores' };
  if (h === '#/standings') return { view: 'standings', tab: 'standings' };
  if (h === '#/traffic') return { view: 'traffic', tab: '' };
  if (h === '#/settings') return { view: 'settings', tab: '' };
  return { view: 'scores', tab: 'scores', home: true };
}
let lastWatch = '';
function render() {
  if (!state) return;
  const r = parseRoute();
  $('btn-theme').hidden = state.mode === 'launcher';          // in the launcher, the launcher owns the theme
  $('halted').hidden = !state.halted;
  versionChip();
  $('btn-home').classList.toggle('active', !!r.home);
  document.querySelectorAll('.tabs a').forEach((a) => a.classList.toggle('active', a.dataset.tab === r.tab));
  const y = window.scrollY;
  const focusId = document.activeElement?.id;
  renderBanner(r.view === 'team' ? r.arg : '');
  renderWeekBar(r.view === 'week' ? Number(r.arg) : 0);
  $('view').innerHTML = views[r.view](r.arg);
  addGloss($('view'));
  tip.hidden = true;
  if (focusId && $(focusId) && focusId.startsWith('set-')) $(focusId).focus();
  window.scrollTo(0, y);
  liveStatus();
  updateWatch(r);
}
function updateWatch(r) {
  // Keys the opt-in timer may refetch: today's scores while they are on screen.
  const keys = r.view === 'scores' && (r.arg || today()) === today() ? [`score:${today()}`] : [];
  const sig = keys.join('|');
  if (sig !== lastWatch) { lastWatch = sig; bridge.request('watch.set', { keys }).catch(() => {}); }
}
window.addEventListener('hashchange', () => { window.scrollTo(0, 0); render(); });

// Live status text, in the navigation bar spec's priority order.
function liveStatus() {
  const el = $('live-status');
  const halted = !!state.halted;
  const errKey = routeKeys.find((k) => store.get(k)?.error);
  const err = !halted && (errKey || state.error);
  const liveN = liveCount() + (state.pretend?.live || 0);
  const live = !halted && !err && liveN > 0;
  const at = routeKeys.map((k) => store.get(k)?.at).filter(Boolean).sort((a, b) => a - b)[0];
  let text;
  if (halted) text = 'Paused';
  else if (err) text = 'Offline';
  else if (!state.settings.autoRefresh) text = at ? `Manual · updated ${ago(at)}` : 'Manual refresh';
  else if (live) text = 'Live';
  else text = at ? `Updated ${ago(at)}` : 'Updated just now';
  el.className = `live-status np-live${live && state.settings.autoRefresh ? ' on' : ''}${err ? ' err' : ''}${halted ? ' halted' : ''}`;
  el.textContent = text;
  const why = err ? `${errKey ? store.get(errKey).error : state.error}\n` : '';
  el.title = halted ? 'All data traffic is paused. Click to resume.' : `${why}${liveN ? liveN + ' game(s) live. ' : ''}Click to pause all data traffic`;
  el.setAttribute('aria-pressed', halted ? 'true' : 'false');
}
setInterval(() => { if (state) liveStatus(); }, 15000);

// Navigation bar behaviour (docs/NAVBAR-SPEC.md).
let navDepth = 0;
window.addEventListener('hashchange', () => { navDepth++; });
const goBack = () => { if (navDepth > 0) { navDepth -= 2; history.back(); } else location.hash = '#/'; };
$('btn-back').addEventListener('click', goBack);
$('btn-fwd').addEventListener('click', () => history.forward());
document.addEventListener('keydown', (e) => {
  if (e.altKey && e.key === 'ArrowLeft') { e.preventDefault(); goBack(); }
  if (e.altKey && e.key === 'ArrowRight') { e.preventDefault(); history.forward(); }
  if (e.key === 'F5') { e.preventDefault(); $('btn-refresh').click(); }
  if (e.key === 'Escape' && !$('dialog').hidden) $('dialog-cancel').click();
  if (e.key === 'Escape' && !$('upd').hidden) $('upd').hidden = true;
});
window.addEventListener('mouseup', (e) => {
  if (e.button === 3) { e.preventDefault(); goBack(); }
  if (e.button === 4) { e.preventDefault(); history.forward(); }
});
$('btn-settings').addEventListener('click', () => { location.hash = '#/settings'; });

// Pause switch: the live-status button and the Resume bar send the same page commands as every other dash.
async function setTraffic(stop) {
  try { state = await bridge.request(stop ? 'traffic.stop' : 'traffic.resume'); render(); } catch (e) { alertNote(e.message); }
}
$('btn-resume').addEventListener('click', () => setTraffic(false));
$('live-status').addEventListener('click', () => setTraffic(!state?.halted));

// Refresh: refetches what the current page shows (including anything that failed).
$('btn-refresh').addEventListener('click', async () => {
  const b = $('btn-refresh');
  if (state?.halted) { alertNote('Data traffic is paused. Resume first.'); return; }
  b.classList.add('spin');
  await Promise.all(routeKeys.map((k) => want(k, true)));
  const t0 = Date.now();
  const iv = setInterval(() => { if (!routeKeys.some((k) => store.get(k)?.loading) || Date.now() - t0 > 20000) { clearInterval(iv); b.classList.remove('spin'); } }, 200);
});

// Search: each dash decides what it searches. The Sample searches teams and the players of loaded team pages.
const res = $('psearch-results');
function searchIndex() {
  const out = Object.keys(TEAMS).map((k) => ({ label: `${teamName(k)} (${k})`, href: `#/team/${k}`, text: `${teamName(k)} ${k}`.toLowerCase() }));
  for (const [k, v] of store) if (k.startsWith('team:') && v.body) for (const p of v.body.players) out.push({ label: `${p.name} · ${k.slice(5)}`, href: `#/${k.replace(':', '/')}`, text: p.name.toLowerCase() });
  return out;
}
$('psearch').addEventListener('input', (e) => {
  const q = e.target.value.trim().toLowerCase();
  if (!q) { res.hidden = true; return; }
  const hits = searchIndex().filter((x) => x.text.includes(q)).slice(0, 12);
  res.innerHTML = hits.length ? hits.map((x) => `<a href="${x.href}">${esc(x.label)}</a>`).join('') : '<div class="empty">No matches</div>';
  res.hidden = false;
});
res.addEventListener('click', () => { res.hidden = true; $('psearch').value = ''; });
document.addEventListener('click', (e) => { if (!e.target.closest('.psearch')) res.hidden = true; });

$('btn-theme').addEventListener('click', () => {
  standaloneTheme = { system: 'light', light: 'dark', dark: 'system' }[standaloneTheme];
  try { localStorage.setItem('theme', standaloneTheme); } catch { }
  bridge.setTheme(standaloneTheme);
  $('btn-theme').textContent = `Theme: ${standaloneTheme}`;
  render();
});

// The same paused state whichever way traffic was stopped: launcher kill switch, live status or Resume.
bridge.on('traffic', (d) => { if (!state) return; state.halted = !!d.stopped; if (d.stopped) store.forEach((v) => { v.loading = false; }); addLog(`traffic: ${d.stopped ? 'stopped' : 'resumed'}`); render(); });
bridge.on('host.theme', (d) => { bridge.setTheme(d.theme); addLog(`host.theme: ${d.theme}`); render(); });
bridge.on('host.hidden', () => addLog('host.hidden: tab hidden'));
bridge.on('host.visible', () => {
  addLog('host.visible: tab shown');
  // Refetch only if automatic refresh is on; otherwise the live status shows how old the data is.
  if (state?.settings.autoRefresh && !state.halted) routeKeys.forEach((k) => want(k, true));
  else if (state) liveStatus();
});

(async () => {
  try { standaloneTheme = localStorage.getItem('theme') || 'system'; } catch { }
  try {
    state = await bridge.request('init');
    if (state.mode !== 'launcher') { bridge.setTheme(standaloneTheme); $('btn-theme').textContent = `Theme: ${standaloneTheme}`; }
    else if (state.theme) bridge.setTheme(state.theme);
    render();
    loadSeason();
    const note = state.updateNote;
    if (note) alertNote(note.ok ? `Updated to version ${note.to}.` : `The update to ${note.to} did not start, so ${note.from} was restored. ${note.reason || ''}`);
    if (state.settings.updateCheck && !note) setTimeout(() => checkUpdate(true), 4000);
  } catch (e) {
    $('view').innerHTML = `<div class="note err">${esc(e.message)}</div>`;
  }
})();
