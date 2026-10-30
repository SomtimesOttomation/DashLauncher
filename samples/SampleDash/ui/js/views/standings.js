// Standings: NBADash's table layout (logo, code, numbers; favourites highlighted; click a row for the team).
import * as S from '../store.js';
import { h, ago } from '../util.js';
import { teamLogo, sectionHead, emptyState, failNote } from '../components.js';
import { calc } from '../formulas.js';

export function mount(ctx) { S.loadStandings(); draw(ctx); }
export function update(topics, ctx) { if (['standings', 'favorites'].some((t) => topics.has(t))) draw(ctx); }

const COLS = [['GP', 'gp', 'gp'], ['W', 'w'], ['L', 'l'], ['OTL', 'otl', 'otl'], ['PTS', 'pts', 'pts'], ['P%', 'ppct', 'ppct'], ['GF', 'gf'], ['GA', 'ga'], ['DIFF', 'diff', 'diff'], ['L10', 'l10', 'l10']];
const val = (t, k) => (k === 'ppct' ? (t.gp ? (t.pts / (2 * t.gp)).toFixed(3).replace(/^0/, '') : '–') : k === 'diff' ? `${t.gf - t.ga > 0 ? '+' : ''}${t.gf - t.ga}` : t[k]);

function draw({ el }) {
  const st = S.state.standings;
  const err = S.keyError('standings');
  if (!st) { el.replaceChildren(err ? failNote(err) : emptyState('Loading standings...', '')); return; }
  const fav = S.favSet();
  el.replaceChildren(
    h('div', { class: 'section-head' }, h('h2', null, 'Standings', h('small', null, 'League'))),
    h('div', { class: 'card scroll-x' }, h('table', { class: 'tbl' },
      h('thead', null, h('tr', null, h('th', null, 'Team'), COLS.map(([l, , c]) => h('th', null, c ? h('span', calc(c), l) : l)))),
      h('tbody', null, st.teams.map((t, i) => h('tr', { class: fav.has(t.code) ? 'me' : '', style: { cursor: 'pointer' }, onclick: () => { location.hash = `#/team/${t.code}`; } },
        h('td', null, h('span', { style: { display: 'inline-flex', alignItems: 'center', gap: '8px' } }, h('small', null, i + 1), teamLogo(t.code, 24), h('b', null, t.code))),
        COLS.map(([, k]) => h('td', null, val(t, k)))))))));
  void sectionHead; void ago;
}
