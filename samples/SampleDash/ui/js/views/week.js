// Week pages: NBADash's week view, built from the saved season (the week bar only links weeks that have data).
import * as S from '../store.js';
import { h, fmtKey } from '../util.js';
import { gameCard, sortEvents, sectionHead, emptyState } from '../components.js';

let week = 0;
export function mount(ctx) { week = Math.max(1, parseInt(ctx.arg, 10) || 1); S.loadStandings(); draw(ctx); }
export function update(topics, ctx) { if (['days', 'favorites', 'teams', 'standings'].some((t) => topics.has(t))) draw(ctx); }

function draw({ el }) {
  const keys = S.weekDayKeys(week).slice().reverse().filter((k) => S.state.cachedDayKeys.includes(k) || S.state.days.has(k));
  const out = [sectionHead(`Week ${week}`, S.weekRangeLabel(week))];
  let games = 0;
  for (const k of keys) {
    const d = S.state.days.get(k);
    if (!d) continue;
    const events = sortEvents(d.events);
    if (!events.length) continue;
    games += events.length;
    out.push(sectionHead(fmtKey(k), `${events.length} game${events.length === 1 ? '' : 's'}`), h('div', { class: 'grid' }, events.map((e) => gameCard(e))));
  }
  if (!games) out.push(emptyState('No games saved for this week', 'Use "Sync the season" in settings to download them.'));
  el.replaceChildren(...out);
}
