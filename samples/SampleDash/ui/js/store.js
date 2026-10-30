// App state and data loading. Views subscribe to topics and re-render. Same API and data shapes as NBADash's store.js
// (state.days, events with sides, favSet, orderedTeams, weeksWithData, sync, update, ...), so NBADash's components and
// views work as they are. Only the data underneath is the Sample's: a made-up league from pretend servers.
//
// To start a real dash, keep this file's shape and replace the data: TEAMS (from your source's team list), the keys
// asked for in loadDay / loadWeek / loadStandings / loadTeamFile, and what bridge.on('data') does with each body.
import * as bridge from './bridge.js';
import { etKey, addDaysKey, asArray, fmtKey } from './util.js';

// The made-up league. A real dash loads its teams from its source (NBADash: the cached teams.json).
export const TEAMS = [
  ['AUR', 'Aurora Comets', '0f766e'], ['BAY', 'Bayside Herons', '1d4ed8'], ['CED', 'Cedar Falls Lynx', '15803d'], ['DUN', 'Dunmore Pilots', 'b45309'],
  ['EMB', 'Ember City Flames', 'dc2626'], ['FOX', 'Foxhollow Rangers', 'ea580c'], ['GLA', 'Glacier Bay Owls', '0284c7'], ['HAR', 'Harbor Point Mariners', '1e3a8a'],
  ['IRO', 'Ironvale Hammers', '4b5563'], ['JUN', 'Juniper Ridge Elk', '65a30d'], ['KES', 'Kestrel Bay Hawks', '7c3aed'], ['LAN', 'Lantern Hill Sparks', 'ca8a04'],
].map(([abbr, name, color]) => ({ abbr, name, color }));

export const state = {
  ready: false,
  host: bridge.isHost,
  version: '',
  teams: TEAMS,
  byAbbr: new Map(TEAMS.map((t) => [t.abbr, t])),
  settings: { favorites: [], theme: 'system', updateCheck: false, autoRefresh: false, autoAck: false, refreshSeconds: 60 },
  days: new Map(),          // 'yyyymmdd' -> { key, events, allFinal, source, at }
  cachedDayKeys: [],
  standings: null,          // { teams: [{ code, gp, w, l, otl, pts, gf, ga, l10 }] }
  teamFiles: new Map(),     // abbr -> { players } | null
  live: { ok: true, at: 0, error: '' },
  sync: { running: false, lastRun: null, text: '', pct: 0, exitCode: null, summary: '', finishedAt: 0 },
  flash: new Map(),         // 'eventId:side' -> time of the last score change
  boxes: new Map(),
  watch: new Set(),
  seasonWeeks: [],          // Mondays of the season, oldest first: week n is seasonWeeks[n - 1]
  pretend: { live: 0, update: false, problem: false, fail: false },
  update: { phase: 'idle', info: null, pct: 0, text: '', error: '', quiet: false, note: null },
  halted: false,
};

// ---- requests and the failed-request rule --------------------------------------------------------------
// Every key the open page asked for is remembered, so Refresh (F5) can ask again. A key that failed is NOT asked for
// again when the page redraws: it waits for Refresh. (Without this, a source that is down gets hammered on every redraw.)
const req = new Map();            // key -> { loading, error }
let routeKeys = new Set();
export const newRoute = () => { routeKeys = new Set(); };
export const keyError = (key) => req.get(key)?.error || '';
async function want(key, { force = false, cacheOnly = false } = {}) {
  routeKeys.add(key);
  const r = req.get(key);
  if (!force && r && (r.loading || r.error || r.done)) return;
  req.set(key, { loading: true, error: '', done: false });
  try {
    const answer = await bridge.request('data.get', { key, force, cacheOnly });
    if (answer === 'missing') req.set(key, { loading: false, error: '', done: true });
  } catch (e) { req.set(key, { loading: false, error: e.message, done: false }); state.live = { ...state.live, error: e.message }; notify('live', 'days'); }
}
// Refresh: everything the open page shows, failed keys included.
export async function refresh() {
  if (state.halted) throw new Error('Data traffic is paused. Resume first.');
  const keys = [...routeKeys];
  if (!keys.length) keys.push(`score:${isoOf(todayKey())}`);
  await Promise.all(keys.map((k) => want(k, { force: true })));
}
export const loading = () => [...routeKeys].some((k) => req.get(k)?.loading);

// ---- season weeks: week 1 is the first Monday the season covers ----------------------------------------
const isoOf = (key) => `${key.slice(0, 4)}-${key.slice(4, 6)}-${key.slice(6, 8)}`;
const keyOf = (iso) => iso.replaceAll('-', '');
const keyToUtc = (k) => Date.UTC(+k.slice(0, 4), +k.slice(4, 6) - 1, +k.slice(6, 8));
export const weekStart = () => (state.seasonWeeks[0] ? keyOf(state.seasonWeeks[0]) : todayKey());
export const weekOfKey = (k) => Math.floor((keyToUtc(k) - keyToUtc(weekStart())) / 86400000 / 7) + 1;
export const weekDayKeys = (n) => Array.from({ length: 7 }, (_, i) => addDaysKey(weekStart(), (n - 1) * 7 + i));
export const weekRangeLabel = (n) => { const d = weekDayKeys(n); const f = (k) => fmtKey(k, { weekday: undefined }); return `${f(d[0])} - ${f(d[6])}`; };
export const weeksWithData = () => [...new Set(state.cachedDayKeys.filter((k) => k >= weekStart()).map(weekOfKey))].sort((a, b) => a - b);
export const todayKey = () => etKey(new Date());
export const yesterdayKey = () => addDaysKey(todayKey(), -1);

// ---- change notification (NBADash's) ----------------------------------------------------------------------
const subs = new Set();
let queued = new Set();
let raf = 0;
export function subscribe(fn) { subs.add(fn); return () => subs.delete(fn); }
export function notify(...topics) {
  topics.forEach((t) => queued.add(t));
  if (raf) return;
  raf = requestAnimationFrame(() => {
    const t = queued; queued = new Set(); raf = 0;
    subs.forEach((fn) => { try { fn(t); } catch (e) { console.error(e); } });
  });
}

// ---- helpers (NBADash's) -------------------------------------------------------------------------------------
function normEvent(ev) {
  const e = { ...ev };
  e.id = String(e.id);
  e.sides = asArray(e.sides).map((s) => ({ ...s, lines: asArray(s.lines), leaders: asArray(s.leaders) }));
  return e;
}
export const side = (ev, which) => ev.sides.find((s) => s.side === which);
export const favSet = () => new Set(state.settings.favorites);
export const isFav = (abbr) => favSet().has(abbr);
export const team = (abbr) => state.byAbbr.get(abbr);
export function recordOf(abbr) {
  const t = (state.standings?.teams || []).find((x) => x.code === abbr);
  return t ? `${t.w}-${t.l}-${t.otl}` : '';
}
export function allEvents() {
  const out = [];
  state.days.forEach((d) => out.push(...d.events));
  return out;
}
export function orderedTeams() {
  const fav = favSet();
  const byName = (a, b) => a.name.localeCompare(b.name);
  const f = state.teams.filter((t) => fav.has(t.abbr)).sort(byName);
  const rest = state.teams.filter((t) => !fav.has(t.abbr)).sort(byName);
  return { favorites: f, others: rest, all: [...f, ...rest] };
}

function setDay(d, source, at) {
  const key = String(d.date);
  const prev = state.days.get(key);
  const next = { key, events: asArray(d.events).map(normEvent), allFinal: asArray(d.events).every((e) => e.state === 'post'), source, at };
  if (prev) {     // score changes flash for a few seconds, as in NBADash
    const old = new Map();
    prev.events.forEach((e) => e.sides.forEach((s) => old.set(`${e.id}:${s.side}`, s.score)));
    next.events.forEach((e) => e.sides.forEach((s) => { const k = `${e.id}:${s.side}`; if (old.has(k) && old.get(k) !== s.score && e.state === 'in') state.flash.set(k, Date.now()); }));
  }
  state.days.set(key, next);
}

// ---- data from the host ---------------------------------------------------------------------------------------
function onData(d) {
  const r = req.get(d.key);
  if (!d.ok) {
    req.set(d.key, { loading: false, error: d.error, done: false });
    state.live = { ...state.live, error: d.error };
    notify('live', 'days', 'standings', 'team');
    return;
  }
  req.set(d.key, { loading: false, error: '', done: true });
  const at = Date.parse(d.at) || Date.now();
  const [kind] = d.key.split(':');
  if (kind === 'score') {
    setDay(d.body, 'live', at);
    if (d.key === `score:${isoOf(todayKey())}`) state.live = { ok: true, at, error: '' };
    notify('days', 'live');
  } else if (kind === 'week') {
    for (const day of asArray(d.body.days)) {
      if (day.date > todayKey()) continue;
      setDay(day, 'saved', at);
      if (!state.cachedDayKeys.includes(day.date)) state.cachedDayKeys.push(day.date);
    }
    notify('days');
  } else if (kind === 'standings') {
    state.standings = d.body; notify('standings', 'days');
  } else if (kind === 'team') {
    state.teamFiles.set(d.key.slice(5), d.body); notify('team');
  }
  void r;
}

// ---- loading (each view asks for what it shows) ---------------------------------------------------------------
export const loadDay = (key, force) => want(`score:${isoOf(key)}`, { force });
export const loadStandings = (force) => want('standings', { force });
export const loadTeamFile = (abbr, force) => want(`team:${abbr}`, { force });
export async function loadSeasonWeeks() {
  try {
    const weeks = asArray(await bridge.request('season.weeks'));
    state.seasonWeeks = weeks.map((w) => w.monday);
    for (const w of weeks) if (w.cached) bridge.request('data.get', { key: `week:${w.monday}`, cacheOnly: true }).catch(() => {});
  } catch { state.seasonWeeks = []; }
  notify('days');
}

// ---- app updates (NBADash's) ------------------------------------------------------------------------------------
function onUpdate(d) {
  const u = state.update;
  if (d.running) {
    u.phase = d.action === 'Stage' ? 'downloading' : 'checking';
    u.pct = d.pct || 0; u.text = d.text || '';
  } else {
    const r = d.result || {};
    u.pct = 0; u.text = ''; u.error = '';
    if (r.status === 'error') { u.phase = 'error'; u.error = r.error || 'The update did not finish.'; }
    else { u.phase = r.status || 'idle'; u.info = r; }
  }
  notify('update');
}
export async function checkUpdate({ quiet = false } = {}) {
  const u = state.update;
  if (u.phase === 'checking' || u.phase === 'downloading') return;
  u.quiet = quiet; u.phase = 'checking'; u.error = ''; u.pct = 0; u.text = 'Asking GitHub for the latest release...';
  notify('update');
  try {
    const started = await bridge.request('update.check');
    if (started === false) { u.phase = u.info?.status === 'available' ? 'available' : 'idle'; notify('update'); }
  } catch (e) { u.phase = 'error'; u.error = e.message; notify('update'); }
}
export async function downloadUpdate() {
  const u = state.update;
  u.quiet = false; u.phase = 'downloading'; u.pct = 0; u.text = 'Starting...'; notify('update');
  try { await bridge.request('update.stage'); } catch (e) { u.phase = 'error'; u.error = e.message; notify('update'); }
}
export async function cancelUpdate() {
  try { await bridge.request('update.cancel'); } catch { /* ignore */ }
  state.update.phase = state.update.info?.status === 'available' ? 'available' : 'idle';
  notify('update');
}
export async function installUpdate() {
  try { await bridge.request('update.apply'); } catch (e) { state.update.phase = 'error'; state.update.error = e.message; notify('update'); }
}
export const updateReady = () => state.update.phase === 'available' || state.update.phase === 'staged';

// ---- actions (NBADash's names) ------------------------------------------------------------------------------------
// In DashLauncher the launcher's theme wins; standalone, the dash's own setting.
export const inLauncher = () => state.hostMode === 'launcher';
export function applyTheme() {
  document.documentElement.dataset.theme = (inLauncher() && state.hostTheme) ? state.hostTheme : (state.settings.theme || 'system');
  notify('theme');
}
function takeSnapshot(snap) {
  if (!snap) return;
  state.settings = { ...state.settings, ...(snap.settings || {}) };
  state.halted = !!snap.halted;
  if (snap.pretend) state.pretend = snap.pretend;
}
// The live status button: same as the launcher's kill switch, started from inside the dash.
export async function stopTraffic() { takeSnapshot(await bridge.request('traffic.stop')); req.forEach((v) => { v.loading = false; }); notify('traffic'); }
export async function resumeTraffic() { takeSnapshot(await bridge.request('traffic.resume')); state.live = { ...state.live, error: '' }; notify('traffic'); }
export async function saveSettings(patch, ack = false) {
  Object.assign(state.settings, patch);
  if ('theme' in patch) applyTheme();
  notify('settings', 'favorites');
  for (const [key, value] of Object.entries(patch)) {
    try { takeSnapshot(await bridge.request('settings.set', { key, value, ack })); } catch (e) { console.warn(e.message); throw e; }
  }
  notify('settings', 'favorites');
}
export function toggleFavorite(abbr) {
  const list = [...state.settings.favorites];
  const i = list.indexOf(abbr);
  if (i >= 0) list.splice(i, 1); else list.push(abbr);
  saveSettings({ favorites: list }).catch(() => {});
}
// Start a sync and show it immediately; the host then streams progress ({running, pct, text}) as 'sync' events.
export async function runSync() {
  try {
    const r = await bridge.request('sync.run');
    if (r && r.started) { state.sync = { ...state.sync, running: true, pct: 0, text: 'Starting...' }; notify('sync'); }
  } catch (e) { throw e; }
}
function onSync(d) {
  const wasRunning = state.sync.running;
  state.sync = { ...state.sync, ...d };
  if (wasRunning && d.running === false) state.sync.finishedAt = Date.now();
  if (d.running === false && !d.cancelled) { loadSeasonWeeks(); want('standings', { force: false, cacheOnly: true }); }
  notify('sync');
}
// Sample tools: pretend states for the launcher's tab badges, and failing downloads.
export async function setPretend(key, value) { takeSnapshot(await bridge.request('sample.set', { key, value })); notify('pretend', 'live'); }

export async function init() {
  await bridge.ready();
  const info = await bridge.request('init');
  takeSnapshot(info);
  state.version = info.version || '';
  state.update.note = info.updateNote || null;
  state.hostMode = info.mode || 'standalone';
  state.hostTheme = info.theme || '';
  applyTheme();

  // host events (dash contract): launcher theme, tab shown again, kill switch
  bridge.on('host.theme', (d) => { state.hostTheme = (d && d.theme) || ''; applyTheme(); });
  bridge.on('host.visible', () => { if (state.settings.autoRefresh && !state.halted) refresh().catch(() => {}); notify('visible'); });
  bridge.on('host.hidden', () => notify('hidden'));
  bridge.on('traffic', (d) => { state.halted = !!(d && d.stopped); notify('traffic'); });
  bridge.on('data', onData);
  bridge.on('sync', onSync);
  bridge.on('update', onUpdate);

  state.ready = true;
  notify('teams', 'favorites');
  loadSeasonWeeks();
  if (state.host && state.settings.updateCheck && !state.update.note) setTimeout(() => checkUpdate({ quiet: true }), 4000);
  return state;
}
