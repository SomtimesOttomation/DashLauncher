// Shared building blocks: logos, status pills, game cards, the team banner and week bar. Copied from NBADash's
// components.js (the gold standard); only the NBA-specific parts are left out (headshots, leaders, live box score lines).
import { h, asArray, fmtTime, fmtDayShort, etKey, num } from './util.js';
import * as S from './store.js';

export const teamColor = (t) => (t && t.color ? `#${t.color}` : '#6b7280');

// ---- logo ------------------------------------------------------------------------------------
// NBADash loads each team's logo from the dash's cache host (https://<id>.cache/logos/...), saved there by its sync, and
// falls back to initials in the team colour. The Sample draws a shield instead, so it downloads nothing.
//
// Wide logos: NBADash's logos are square, so they fill their box. Some leagues' artwork is wider than tall with built-in
// margins (the NHL's SVGs are 3:2), so it draws about a third smaller in the same box. Scale such logos up inside their
// box (NHLDash uses `transform: scale(1.32)` on the img) and keep `pointer-events: none` on the img and a higher z-index
// on the favourite star (.tile-star), or the enlarged logo covers the star and it can no longer be clicked.
function shield(abbr, color) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><path d="M32 4 56 12v20c0 14-10 23-24 28C18 55 8 46 8 32V12z" fill="${color}"/><path d="M32 10 50 16v16c0 10-7 17-18 21-11-4-18-11-18-21V16z" fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="2"/><text x="32" y="39" font-family="Segoe UI,Arial" font-size="15" font-weight="700" fill="#fff" text-anchor="middle">${abbr}</text></svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}
export function teamLogo(abbr, size = 40) {
  const t = S.team(abbr);
  const wrap = h('span', { class: 'logo', style: { '--s': `${size}px`, '--tc': teamColor(t) }, 'data-abbr': abbr });
  const img = h('img', { src: shield(abbr, teamColor(t)), alt: '', width: size, height: size, loading: 'lazy', decoding: 'async' });
  img.addEventListener('error', () => {
    img.remove();
    wrap.classList.add('logo-fallback');
    wrap.append(String(abbr).slice(0, 3));
  });
  wrap.append(img);
  return wrap;
}

export function teamName(abbr) {
  const t = S.team(abbr);
  return t ? t.name : abbr;
}

// ---- status ------------------------------------------------------------------------------------
// NBADash shows quarters (Q1-Q4, OT). The Sample's pretend sport has three periods; change this for your sport.
export function periodLabel(p) {
  p = Number(p) || 0;
  if (p <= 3) return `P${p}`;
  return p === 4 ? 'OT' : `${p - 3}OT`;
}

export function statusInfo(ev) {
  const today = S.todayKey();
  if (ev.state === 'in') return { kind: 'live', text: `${periodLabel(ev.period)}${ev.clock ? ' ' + ev.clock : ''}`, label: 'LIVE' };
  if (ev.state === 'post') {
    const p = Number(ev.period) || 3;
    return { kind: 'final', text: p > 3 ? `FINAL / ${periodLabel(p)}` : 'FINAL', label: '' };
  }
  const dayKey = etKey(new Date(ev.date));
  const when = dayKey === today ? fmtTime(ev.date) : `${fmtDayShort(ev.date)} ${fmtTime(ev.date)}`;
  const detail = String(ev.detail || '');
  if (/postponed|canceled|cancelled|delayed/i.test(detail)) return { kind: 'pre', text: detail.toUpperCase(), label: '' };
  return { kind: 'pre', text: when, label: '' };
}

export function statusPill(ev) {
  const s = statusInfo(ev);
  return h('span', { class: `pill pill-${s.kind}` },
    s.kind === 'live' ? h('i', { class: 'dot', 'aria-hidden': 'true' }) : null,
    s.kind === 'live' ? h('b', null, 'LIVE') : null,
    h('span', null, s.text));
}

// ---- star ------------------------------------------------------------------------------------------
export function starButton(abbr, cls = '') {
  const on = S.isFav(abbr);
  return h('button', {
    class: `star ${on ? 'on' : ''} ${cls}`, type: 'button',
    title: on ? 'Remove from favorites' : 'Add to favorites', 'aria-pressed': on ? 'true' : 'false',
    onclick: (e) => { e.preventDefault(); e.stopPropagation(); S.toggleFavorite(abbr); },
  }, on ? '★' : '☆');
}

// ---- ordering -----------------------------------------------------------------------------------------
export function sortEvents(events) {
  const fav = S.favSet();
  const rank = (e) => (e.sides.some((s) => fav.has(s.abbr)) ? 0 : 1);
  const st = (e) => (e.state === 'in' ? 0 : e.state === 'pre' ? 1 : 2);
  return [...events].sort((a, b) => rank(a) - rank(b) || st(a) - st(b) || Date.parse(a.date) - Date.parse(b.date));
}

// ---- game card ------------------------------------------------------------------------------------------
function sideRow(ev, sd, opts) {
  const t = S.team(sd.abbr);
  const flash = S.state.flash.get(`${ev.id}:${sd.side}`);
  const justScored = flash && Date.now() - flash < 4000;
  const scoreNum = num(sd.score);
  const other = ev.sides.find((x) => x !== sd);
  const oScore = other ? num(other.score) : NaN;
  const winner = ev.state === 'post' && Number.isFinite(scoreNum) && Number.isFinite(oScore) && scoreNum > oScore;
  const loser = ev.state === 'post' && Number.isFinite(scoreNum) && Number.isFinite(oScore) && scoreNum < oScore;
  const focus = opts.focus === sd.abbr;
  const record = sd.record || S.recordOf(sd.abbr);
  return h('div', { class: `side ${winner ? 'win' : ''} ${loser ? 'lose' : ''} ${focus ? 'focus' : ''}`, style: { '--tc': teamColor(t) } },
    h('a', { class: 'side-team', href: `#/team/${sd.abbr}`, onclick: (e) => e.stopPropagation(), title: sd.name || teamName(sd.abbr) },
      teamLogo(sd.abbr, opts.wide ? 88 : 68),
      h('span', { class: 'side-names' },
        h('b', null, opts.wide ? (sd.name || teamName(sd.abbr)) : sd.abbr),
        h('small', null, [opts.wide ? sd.abbr : '', record].filter(Boolean).join(' · ')))),
    ev.state === 'pre' ? h('span', { class: 'score muted' }, '–')
      : h('span', { class: `score ${justScored ? 'bump' : ''}` }, sd.score ?? '–'));
}

export function gameCard(ev, opts = {}) {
  const away = S.side(ev, 'away') || ev.sides[0];
  const home = S.side(ev, 'home') || ev.sides[1];
  const fav = S.favSet();
  const isFavGame = [away, home].some((s) => s && fav.has(s.abbr));
  // NBADash opens the game page (#/game/<id>); the Sample has no game page, so the card opens the home team.
  const go = () => { location.hash = `#/team/${home?.abbr || ''}`; };
  return h('article', {
    class: `card game ${ev.state} ${opts.wide ? 'wide' : ''} ${isFavGame ? 'fav' : ''}`,
    tabindex: '0', role: 'link', 'aria-label': `${teamName(away?.abbr)} at ${teamName(home?.abbr)}`,
    onclick: go, onkeydown: (e) => { if (e.key === 'Enter') go(); },
  },
    h('header', { class: 'game-head' },
      statusPill(ev),
      h('span', { class: 'game-head-right' }, isFavGame ? h('span', { class: 'fav-tag', title: 'Favorite team' }, '★') : null)),
    h('div', { class: 'sides' }, away ? sideRow(ev, away, opts) : null, home ? sideRow(ev, home, opts) : null),
    h('footer', { class: 'game-foot' }, h('span', { class: 'venue' }, ev.venue || '')));
}

// ---- week bar and banner ------------------------------------------------------------------------------------------
// "Week 1 | Week 2 | ..." under the team banner; only weeks that have saved games are linked.
export function renderWeekBar(el, activeWeek) {
  const weeks = S.weeksWithData();
  el.hidden = weeks.length === 0;
  el.replaceChildren(h('span', { class: 'weekbar-label' }, 'Season'),
    ...weeks.map((n) => h('a', { class: `weeklink ${n === activeWeek ? 'active' : ''}`, href: `#/week/${n}`, title: S.weekRangeLabel(n) }, `Week ${n}`)));
}

export function renderBanner(el, activeAbbr) {
  const { favorites, others } = S.orderedTeams();
  el.replaceChildren();
  const strip = h('div', { class: 'banner-strip', role: 'list' });
  const tile = (t, isFav) => h('a', {
    class: `tile ${isFav ? 'fav' : ''} ${t.abbr === activeAbbr ? 'active' : ''}`, href: `#/team/${t.abbr}`, role: 'listitem',
    title: t.name, style: { '--tc': teamColor(t) },
  }, starButton(t.abbr, 'tile-star'), teamLogo(t.abbr, 92), h('span', { class: 'tile-code' }, t.abbr));
  favorites.forEach((t) => strip.append(tile(t, true)));
  if (favorites.length) strip.append(h('span', { class: 'banner-divider', 'aria-hidden': 'true' }));
  others.forEach((t) => strip.append(tile(t, false)));

  const scroll = (dir) => strip.scrollBy({ left: dir * Math.max(300, strip.clientWidth * 0.8), behavior: 'smooth' });
  const left = h('button', { class: 'banner-btn left', type: 'button', 'aria-label': 'Scroll teams left', onclick: () => scroll(-1) }, '‹');
  const right = h('button', { class: 'banner-btn right', type: 'button', 'aria-label': 'Scroll teams right', onclick: () => scroll(1) }, '›');
  strip.addEventListener('wheel', (e) => {
    if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) { strip.scrollLeft += e.deltaY; e.preventDefault(); }
  }, { passive: false });
  const update = () => {
    left.classList.toggle('hide', strip.scrollLeft < 8);
    right.classList.toggle('hide', strip.scrollLeft + strip.clientWidth >= strip.scrollWidth - 8);
  };
  strip.addEventListener('scroll', update, { passive: true });
  el.append(left, strip, right);
  requestAnimationFrame(() => {
    const active = strip.querySelector('.tile.active');
    if (active) active.scrollIntoView({ inline: 'center', block: 'nearest' });
    update();
  });
}

// ---- small pieces ------------------------------------------------------------------------------------------------
export const emptyState = (title, body, action) =>
  h('div', { class: 'empty' }, h('h3', null, title), body ? h('p', null, body) : null, action || null);

export function skeletonCards(n = 3) {
  return h('div', { class: 'grid' }, Array.from({ length: n }, () => h('div', { class: 'card skeleton' })));
}

export function sectionHead(title, sub, right) {
  return h('div', { class: 'section-head' },
    h('h2', null, title, sub ? h('small', null, sub) : null),
    right || null);
}

// A failed request, as a note with the Refresh hint (the page never retries on its own).
export function failNote(err) {
  return emptyState('Could not load', `${err} Press Refresh (F5) to try again.`);
}

export { asArray };
