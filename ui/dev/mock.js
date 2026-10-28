// Mock host for previewing the rail and notice pages in a normal browser.
//   rail.html?theme=dark        panel.html#locked  (locked | error | broken | declined | empty)
const nbaIcon = 'data:image/svg+xml;base64,' + btoa('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><circle cx="16" cy="16" r="14" fill="#e8622c"/><g fill="none" stroke="#1d1d1f" stroke-width="1.6"><circle cx="16" cy="16" r="14"/><path d="M2 16h28M16 2v28M6.1 6.1c4.6 4.4 4.6 15.4 0 19.8M25.9 6.1c-4.6 4.4-4.6 15.4 0 19.8"/></g></svg>');
const f1Icon = 'data:image/svg+xml;base64,' + btoa('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect x="3" y="7" width="26" height="18" rx="3" fill="#1f2937"/><g fill="#fff"><rect x="5" y="9" width="4" height="4"/><rect x="13" y="9" width="4" height="4"/><rect x="21" y="9" width="4" height="4"/><rect x="9" y="13" width="4" height="4"/><rect x="17" y="13" width="4" height="4"/><rect x="5" y="17" width="4" height="4"/><rect x="13" y="17" width="4" height="4"/><rect x="21" y="17" width="4" height="4"/></g></svg>');

const params = new URLSearchParams(location.search);
let theme = params.get('theme') || 'system';
let emit = () => {};
const tabs = [
  { id: 'nbadash', name: 'NBA', title: 'NBA 2026-27', version: '0.11.0', state: 'ready', icon: nbaIcon, live: 3, syncing: false, syncPct: null, update: '0.12.0', statusError: null, error: '' },
  { id: 'f1dash', name: 'F1', title: 'F1 2026', version: '0.1.0', state: 'ready', icon: f1Icon, live: 0, syncing: true, syncPct: 40, update: null, statusError: null, error: '' },
  { id: 'fadash', name: 'Football', title: 'FA Dash', version: '0.1.0', state: 'locked', icon: '', live: 0, syncing: false, syncPct: null, update: null, statusError: null, error: '' },
  { id: 'f1get', name: 'F1', title: 'F1 2026', version: '0.3.0', state: 'available', icon: f1Icon, live: 0, syncing: false, syncPct: null, update: null, statusError: null, error: '' },
  { id: 'sample', name: 'Sample', title: 'Sample Dash', version: '0.1.0', state: 'declined', icon: '', live: 0, syncing: false, syncPct: null, update: null, statusError: null, error: '' },
  { id: 'broken1', name: 'OldDash', title: '', version: '', state: 'broken', icon: '', live: 0, syncing: false, syncPct: null, update: null, statusError: null, error: '"backend" not found: modules/Old.Host.psm1' },
];
let active = 'nbadash';

const notices = {
  locked: { kind: 'locked', id: 'fadash', name: 'Football', title: 'FA Dash', version: '0.1.0', folder: 'C:\\Tools\\DashLauncher\\modules\\FADash' },
  error: { kind: 'error', id: 'f1dash', name: 'F1', title: 'F1 2026', version: '0.1.0', folder: 'C:\\Tools\\DashLauncher\\modules\\F1Dash', message: 'Its backend does not export Stop-DashTraffic (dash contract 1).' },
  broken: { kind: 'broken', id: 'broken1', name: 'OldDash', folder: 'C:\\Tools\\DashLauncher\\modules\\OldDash', message: '"backend" not found: modules/Old.Host.psm1' },
  declined: { kind: 'declined', id: 'sample', name: 'Sample', title: 'Sample Dash', version: '0.1.0', folder: 'C:\\Tools\\DashLauncher\\modules\\SampleDash' },
  available: { kind: 'available', id: 'nbadash', name: 'NBA', title: 'NBA 2026-27', repo: 'SomtimesOttomation/NBADash', version: '0.12.0', publishedAt: '2026-10-26T14:00:00Z', assetName: 'NBADash-v0.12.0.zip', hasAsset: true, hasSha: true, source: 'github', install: location.search.includes('installing') ? { id: 'nbadash', status: 'installing', pct: 46, text: 'Downloading 0.3 of 0.7 MB' } : null, modulesDir: 'C:\\Tools\\DashLauncher\\modules', target: 'C:\\Tools\\DashLauncher\\modules\\NBADash' },
  missing: { kind: 'missing', id: 'nbadash', name: 'NBA', title: 'NBA 2026-27', version: '0.12.0', folder: 'C:\\Tools\\DashLauncher\\modules\\NBADash' },
  update: { kind: 'update', updateCheck: true,
    modules: {
      enabled: !location.search.includes('modoff'), checking: false, checkedAt: '2026-10-28T13:10:00Z',
      run: location.search.includes('modrun') ? { status: 'updating', total: 2, index: 1, current: 'nbadash', pct: 46, text: 'Downloading 0.3 of 0.7 MB' } : { status: 'idle' },
      items: [
        { id: 'nbadash', name: 'NBA', title: 'NBA 2026-27', current: '0.12.0', latest: '0.15.0', state: 'update', note: '' },
        { id: 'f1dash', name: 'F1', title: 'F1 2026', current: '0.1.0', latest: '0.2.0', state: 'update', note: '' },
        { id: 'fadash', name: 'Football', title: 'FA Dash', current: '0.3.0', latest: '0.3.0', state: 'current', note: '' },
        { id: 'sample', name: 'Sample', title: 'Sample Dash', current: '0.1.0', latest: '', state: 'notlisted', note: "Not in DashLauncher's list of modules: update it from inside the dashboard." },
      ],
    }, update: { status: location.search.includes('staged') ? 'staged' : 'available', current: '0.2.0', latest: '0.3.0', published: '2026-11-02T12:00:00Z', installable: true, pct: 0, text: '',
    notes: '**Feature**\n- Settings page for the launcher\n- Drag tabs to reorder\n\n**Bug/Fix**\n- Fixed the stop button toast in dark mode.' } },
  empty: { kind: 'empty', modulesDir: 'C:\\Tools\\DashLauncher\\modules', scanFolders: ['C:\\Tools\\DashLauncher\\modules'] },
};

export function attach(fn) { emit = fn; }

export async function request(cmd, args) {
  await new Promise((r) => setTimeout(r, 30));
  switch (cmd) {
    case 'rail.init':
      setTimeout(() => emit('tabs', { tabs, active, theme, launcherUpdate: '0.3.0', overlay: location.hash === '#update' ? 'update' : '' }), 10);
      return { version: '0.2.0', theme, debug: true };
    case 'tab.select': active = args.id; setTimeout(() => emit('tabs', { tabs, active, theme }), 10); return true;
    case 'theme.set': theme = args.theme; return true;
    case 'app.restart': return window.confirm('Mock: restart DashLauncher?') ? true : false;
    case 'modules.scan': return { added: 1, removed: 0, broken: 0, total: tabs.length };
    case 'traffic.stop': return window.confirm('Stop all traffic in every dashboard now?') ? 2 : 0;
    case 'panel.get': return { notice: notices[location.hash.slice(1)] || notices.locked, theme };
    case 'mod.auto': case 'mod.check': case 'mod.update':
    case 'catalog.install': case 'update.open': case 'update.close': case 'update.check': case 'update.stage': case 'update.apply': case 'update.auto': case 'update.cancel': case 'tab.retry': case 'tab.approve': case 'tab.close': case 'catalog.download': case 'modules.open': return true;
    case 'tab.switchTo': case 'tab.reload': return false;
    default: throw new Error(`mock: unknown command ${cmd}`);
  }
}
