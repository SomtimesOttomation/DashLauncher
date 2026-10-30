// Team page: NBADash's hero (96 px logo, name, star, record) above the roster table.
import * as S from '../store.js';
import { h } from '../util.js';
import { teamLogo, teamColor, starButton, emptyState, failNote } from '../components.js';
import { calc } from '../formulas.js';

export function mount(ctx) { S.loadTeamFile(ctx.arg); S.loadStandings(); draw(ctx); }
export function update(topics, ctx) { if (['team', 'standings', 'favorites', 'sync'].some((t) => topics.has(t))) draw(ctx); }

function draw({ el, arg }) {
  const t = S.team(arg);
  if (!t) { el.replaceChildren(emptyState('Unknown team', arg)); return; }
  const file = S.state.teamFiles.get(arg);
  const st = (S.state.standings?.teams || []).find((x) => x.code === arg);
  const hero = h('section', { class: 'card hero', style: { '--tc': teamColor(t) } },
    teamLogo(arg, 96),
    h('div', null,
      h('h1', null, t.name, ' ', starButton(arg)),
      h('div', { class: 'meta' }, st ? `${st.w}-${st.l}-${st.otl} · ${st.pts} points` : ''),
      st ? h('dl', { class: 'kv', style: { marginTop: '8px' } },
        h('dt', null, h('span', calc('ppct'), 'Points %')), h('dd', null, st.gp ? (st.pts / (2 * st.gp)).toFixed(3).replace(/^0/, '') : '–'),
        h('dt', null, h('span', calc('l10'), 'Last 10')), h('dd', null, st.l10)) : null));
  const err = S.keyError(`team:${arg}`);
  const head = (label, key) => h('th', null, key ? h('span', calc(key, 'player'), label) : label);
  const body = file
    ? h('div', { class: 'card scroll-x' }, h('table', { class: 'tbl roster' },
      h('thead', null, h('tr', null, head('Player'), head('Pos'), head('GP', 'gp'), head('G'), head('A'), head('P'), head('+/-', 'pm'), head('SOG', 'sog'))),
      h('tbody', null, file.players.map((p) => h('tr', null, h('td', null, h('b', null, p.name)), h('td', null, p.pos), h('td', null, p.gp), h('td', null, p.g),
        h('td', null, p.a), h('td', null, h('b', null, p.pts)), h('td', null, `${p.pm > 0 ? '+' : ''}${p.pm}`), h('td', null, p.sog))))))
    : err ? failNote(err) : emptyState('Loading...', '');
  el.replaceChildren(hero, body);
}
