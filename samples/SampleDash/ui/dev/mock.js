// Browser preview host, like NBADash's ui/dev/mock.js: open ui/index.html from a local web server (for example
// `python -m http.server` in the ui folder) and the page runs without PowerShell or WebView2. It answers the same
// commands as the backend with a small made-up league. Dev only: the real host never loads this file.
let emit = () => {};
export function attach(fn) { emit = fn; }

const CODES = ['AUR', 'BAY', 'CED', 'DUN', 'EMB', 'FOX', 'GLA', 'HAR', 'IRO', 'JUN', 'KES', 'LAN'];
const settings = { theme: new URLSearchParams(location.search).get('theme') || 'system', autoRefresh: false, autoAck: false, refreshSeconds: 60, favorites: [], updateCheck: false };
const pretend = { live: 0, update: false, problem: false, fail: false };
const traffic = { requests: 0, bytes: 0, errors: 0, byKind: {}, byHost: {}, last: [] };
const saved = new Set();
let halted = false;

const seed = (s) => { let x = 17; for (const c of s) x = (x * 31 + c.charCodeAt(0)) % 2147483647; return () => (x = (x * 48271) % 2147483647) / 2147483647; };
const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const monday = (d) => { const x = new Date(d); x.setHours(12, 0, 0, 0); while (x.getDay() !== 1) x.setDate(x.getDate() - 1); return x; };
const seasonStart = () => { const d = new Date(); d.setDate(d.getDate() - 42); return monday(d); };

function day(dateIso) {
  const rnd = seed(dateIso);
  const codes = [...CODES].sort(() => rnd() - 0.5);
  const now = new Date(), isToday = dateIso === iso(now);
  const n = 3 + Math.floor(rnd() * 3);
  const events = [];
  for (let i = 0; i < n; i++) {
    const start = isToday ? new Date(now.getTime() + [-180, -40, i * 60][Math.min(i, 2)] * 60000) : new Date(`${dateIso}T${18 + i}:00:00`);
    let a = Math.floor(rnd() * 6), hm = Math.floor(rnd() * 6), ot = false;
    if (a === hm) { hm++; ot = true; }
    const mins = (now - start) / 60000;
    const state = dateIso < iso(now) || (isToday && mins >= 150) ? 'post' : isToday && mins >= 0 ? 'in' : 'pre';
    if (state === 'in') { a = Math.floor(a * mins / 150); hm = Math.floor(hm * mins / 150); ot = false; }
    events.push({ id: `${dateIso.replaceAll('-', '')}${i}`, state, date: start.toISOString(), period: state === 'in' ? Math.min(3, 1 + Math.floor(mins / 45)) : state === 'post' ? (ot ? 4 : 3) : 0,
      clock: state === 'in' ? `${String(19 - Math.floor(mins % 20)).padStart(2, '0')}:${String(Math.floor(rnd() * 60)).padStart(2, '0')}` : '', detail: '', venue: `${codes[2 * i + 1]} Arena`,
      sides: [{ side: 'away', abbr: codes[2 * i], score: state === 'pre' ? null : String(a), leaders: [] }, { side: 'home', abbr: codes[2 * i + 1], score: state === 'pre' ? null : String(hm), leaders: [] }] });
  }
  return { date: dateIso.replaceAll('-', ''), events };
}
function standings() {
  const r = Object.fromEntries(CODES.map((c) => [c, { code: c, gp: 0, w: 0, l: 0, otl: 0, pts: 0, gf: 0, ga: 0, form: [] }]));
  for (let d = seasonStart(); iso(d) < iso(new Date()); d.setDate(d.getDate() + 1)) {
    for (const e of day(iso(d)).events) {
      const [aw, hm] = e.sides; const ot = e.period > 3;
      for (const [me, op] of [[aw, hm], [hm, aw]]) {
        const t = r[me.abbr]; t.gp++; t.gf += +me.score; t.ga += +op.score;
        if (+me.score > +op.score) { t.w++; t.pts += 2; t.form.push('W'); } else if (ot) { t.otl++; t.pts++; t.form.push('O'); } else { t.l++; t.form.push('L'); }
      }
    }
  }
  return { teams: Object.values(r).map((t) => { const f = t.form.slice(-10); delete t.form; return { ...t, l10: `${f.filter((x) => x === 'W').length}-${f.filter((x) => x === 'L').length}-${f.filter((x) => x === 'O').length}` }; }).sort((a, b) => b.pts - a.pts || (b.gf - b.ga) - (a.gf - a.ga)) };
}
function teamFile(code) {
  const rnd = seed(code);
  const first = ['Alex', 'Sam', 'Jordan', 'Riley', 'Casey', 'Morgan', 'Jamie', 'Taylor'], last = ['Hale', 'Moreau', 'Okafor', 'Brandt', 'Castell', 'Rook', 'Vance', 'Pike'];
  const players = Array.from({ length: 12 }, (_, i) => { const g = Math.floor(rnd() * 9), a = Math.floor(rnd() * 12); return { id: `${code}${i}`, name: `${first[Math.floor(rnd() * 8)]} ${last[Math.floor(rnd() * 8)]}`, pos: ['F', 'F', 'D'][i % 3], gp: 10 + Math.floor(rnd() * 8), g, a, pts: g + a, pm: Math.floor(rnd() * 15) - 7, sog: g * 4 + Math.floor(rnd() * 25) }; });
  return { code, players: players.sort((x, y) => y.pts - x.pts) };
}
function body(key) {
  const [kind, arg] = key.split(':');
  if (kind === 'score') return day(arg);
  if (kind === 'week') { const m = new Date(`${arg}T12:00:00`); return { monday: arg, days: Array.from({ length: 7 }, (_, i) => { const d = new Date(m); d.setDate(d.getDate() + i); return day(iso(d)); }) }; }
  if (kind === 'team') return teamFile(arg);
  return standings();
}
function fetchKey(key) {
  setTimeout(() => {
    const kind = key.split(':')[0];
    traffic.requests++;
    const host = kind === 'team' ? 'teams.sample.invalid' : 'scores.sample.invalid';
    traffic.byHost[host] ||= { requests: 0, bytes: 0, errors: 0 }; traffic.byHost[host].requests++;
    traffic.byKind[kind] ||= { requests: 0, bytes: 0 }; traffic.byKind[kind].requests++;
    if (pretend.fail) {
      traffic.errors++; traffic.byHost[host].errors++;
      traffic.last.unshift({ at: new Date().toISOString(), key, bytes: 0, ms: 0, ok: false });
      emit('data', { key, ok: false, error: 'Pretend download failure (Sample tools).' }); return;
    }
    const b = body(key); const n = JSON.stringify(b).length;
    traffic.bytes += n; traffic.byHost[host].bytes += n; traffic.byKind[kind].bytes += n;
    traffic.last.unshift({ at: new Date().toISOString(), key, bytes: n, ms: 180, ok: true }); traffic.last.length = Math.min(traffic.last.length, 40);
    if (kind === 'week') saved.add(key.slice(5));
    emit('data', { key, ok: true, cached: false, at: new Date().toISOString(), body: b });
  }, 150);
}
const snap = () => ({ mode: 'standalone', version: '0.1.0', theme: '', settings, pretend, halted, live: pretend.live, today: iso(new Date()), traffic: { requests: traffic.requests, bytes: traffic.bytes, errors: traffic.errors } });
function weeks() { const out = []; for (let d = seasonStart(); d <= new Date(); d.setDate(d.getDate() + 7)) out.push({ monday: iso(d), cached: saved.has(iso(d)) }); return out; }

export async function request(cmd, args = {}) {
  await new Promise((r) => setTimeout(r, 20));
  switch (cmd) {
    case 'init': return snap();
    case 'season.weeks': return weeks();
    case 'watch.set': return true;
    case 'data.get':
      if (halted) throw new Error('Data traffic is paused.');
      if (args.cacheOnly) { if (args.key.startsWith('week:') && saved.has(args.key.slice(5))) { emit('data', { key: args.key, ok: true, cached: true, at: new Date().toISOString(), body: body(args.key) }); return 'cached'; } return 'missing'; }
      fetchKey(args.key); return 'queued';
    case 'settings.set': settings[args.key] = args.value; return snap();
    case 'sample.set': pretend[args.key] = args.key === 'live' ? Math.max(0, args.value) : args.value; return snap();
    case 'traffic.get': return { uptimeSec: Math.round(performance.now() / 1000), ...traffic, last: traffic.last[0] ? traffic.last[0].key : '', lastList: traffic.last };
    case 'traffic.stop': halted = true; emit('traffic', { stopped: true }); return snap();
    case 'traffic.resume': halted = false; emit('traffic', { stopped: false }); return snap();
    case 'sync.run': {
      const w = weeks(); let i = 0;
      const step = () => { if (i >= w.length) { emit('sync', { running: false, pct: 100, exitCode: 0, summary: `${w.length} requests`, lastRun: new Date().toISOString() }); return; }
        fetchKey(`week:${w[i].monday}`); i++; emit('sync', { running: true, pct: Math.round(100 * i / w.length), text: `Downloading ${i} of ${w.length}` }); setTimeout(step, 250); };
      setTimeout(step, 50); return { started: true, requests: w.length };
    }
    case 'sync.cancel': return true;
    case 'cache.clear': saved.clear(); return true;
    case 'update.check': setTimeout(() => emit('update', { running: false, action: 'Check', result: { status: 'none' } }), 300); return true;
    default: throw new Error(`mock: unknown command ${cmd}`);
  }
}
