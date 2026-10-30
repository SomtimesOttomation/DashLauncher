// Scores: NBADash's home view. A left-aligned heading per day ("Today · date · N games · N live"), then the game grid.
import * as S from '../store.js';
import { h, fmtKey } from '../util.js';
import { gameCard, sortEvents, sectionHead, emptyState, skeletonCards, failNote } from '../components.js';

export function mount(ctx) { draw(ctx); S.loadDay(S.todayKey()); S.loadDay(S.yesterdayKey()); S.loadStandings(); }
export function update(topics, ctx) {
  if (['days', 'favorites', 'teams', 'sync', 'standings', 'settings', 'live'].some((t) => topics.has(t))) draw(ctx);
}

function section(key, title) {
  const d = S.state.days.get(key);
  if (!d) return null;
  return { key, title, events: sortEvents(d.events) };
}

function draw({ el }) {
  const today = S.todayKey(), yest = S.yesterdayKey();
  const sections = [section(today, 'Today'), section(yest, 'Last night')].filter(Boolean);
  const out = [];
  const fav = S.favSet();
  if (fav.size === 0) out.push(h('div', { class: 'card pad', style: { marginBottom: '18px' } },
    h('b', null, 'Pick your teams. '), 'Click the ☆ on any logo above: favorites move to the front and their games are shown first.'));
  for (const s of sections) {
    const live = s.events.filter((e) => e.state === 'in').length;
    out.push(sectionHead(s.title, `${fmtKey(s.key)} · ${s.events.length} game${s.events.length === 1 ? '' : 's'}${live ? ` · ${live} live` : ''}`));
    out.push(s.events.length
      ? h('div', { class: 'grid' }, s.events.map((e) => gameCard(e)))
      : emptyState('No games', 'Nothing scheduled for this day.'));
  }
  if (!S.state.settings.autoRefresh && S.state.host) {
    out.unshift(h('div', { class: 'card pad', style: { marginBottom: '18px', display: 'flex', gap: '12px', alignItems: 'center', flexWrap: 'wrap' } },
      h('span', null, h('b', null, 'Automatic refresh is off. '), 'Scores only update when you ask. Use the ', h('b', null, '↻'), ' button (or F5) for the latest scores, or '),
      h('button', { class: 'btn', type: 'button', onclick: () => S.runSync().catch(() => {}) }, 'Sync the season'),
      h('button', { class: 'btn', type: 'button', onclick: () => import('./settings.js').then((m) => m.openSettings()) }, 'Automatic refresh options')));
  }
  const err = S.keyError(`score:${today.slice(0, 4)}-${today.slice(4, 6)}-${today.slice(6, 8)}`);
  if (!sections.length) out.push(err ? failNote(err) : S.state.ready ? emptyState('Nothing loaded yet', 'Press the refresh button or F5.') : skeletonCards(6));
  el.replaceChildren(...out);
}
