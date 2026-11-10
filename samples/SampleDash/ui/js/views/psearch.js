// Search box in the navigation bar: NBADash's views/psearch.js (ghost completion, "/" to focus, Esc to clear,
// arrows + Enter, Tab or Right arrow to accept the suggestion, recent picks), searching what the Sample has locally:
// every club in every league, and the players of club pages already loaded. A real dash decides what it searches and
// may ask its source when the local answer is thin (NBADash asks ESPN after 3 letters).
import * as S from '../store.js';
import { h } from '../util.js';
import { teamLogo } from '../components.js';

const RECENT_KEY = 'sample.recentSearch';
const recents = () => { try { return JSON.parse(localStorage.getItem(RECENT_KEY)) || []; } catch { return []; } };
const clearRecents = () => { try { localStorage.removeItem(RECENT_KEY); } catch { /* ignore */ } };
const remember = (it) => {
  try { localStorage.setItem(RECENT_KEY, JSON.stringify([{ id: it.id, name: it.name, team: it.team, sub: it.sub, href: it.href }, ...recents().filter((r) => r.id !== it.id)].slice(0, 6))); } catch { /* ignore */ }
};
// Lower case without accents, so "e" finds "é".
export const fold = (s) => String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

function index() {
  const items = S.state.teams.map((t) => ({ id: `t:${t.abbr}`, name: t.name, team: t.abbr, href: `#/team/${t.abbr}`,
    sub: [t.abbr, S.league(t.league)?.name].filter(Boolean).join(' · ') }));
  S.state.teamFiles.forEach((f, abbr) => (f?.players || []).forEach((p) => items.push({ id: `p:${p.id}`, name: p.name, team: abbr, href: `#/team/${abbr}`, sub: [abbr, p.pos].filter(Boolean).join(' · ') })));
  return items;
}
function search(q) {
  const words = fold(q).split(' ').filter(Boolean);
  if (!words.length) return [];
  const score = (it) => { const n = fold(it.name); return n.startsWith(words[0]) ? 0 : n.split(' ').some((w) => w.startsWith(words[0])) ? 1 : 2; };
  return index().filter((it) => { const n = fold(`${it.name} ${it.team}`); return words.every((w) => n.includes(w)); })
    .sort((a, b) => score(a) - score(b) || a.name.localeCompare(b.name)).slice(0, 12);
}

// Bold the part of the name the person has typed.
function highlight(name, q) {
  const words = fold(q).split(' ').filter(Boolean);
  const lower = fold(name);
  if (!words.length || lower.length !== name.length) return name;
  const parts = []; let i = 0;
  while (i < name.length) {
    const hit = words.find((w) => lower.startsWith(w, i) && (i === 0 || lower[i - 1] === ' '));
    if (hit) { parts.push(h('mark', null, name.slice(i, i + hit.length))); i += hit.length; } else { parts.push(name[i]); i++; }
  }
  return parts;
}

export function initSearch() {
  const input = document.getElementById('psearch');
  const box = document.getElementById('psearch-results');
  const ghost = document.getElementById('psearch-ghost');
  if (!input || !box || !ghost) return;
  let items = [];
  let active = -1;

  const close = () => { box.hidden = true; active = -1; };
  const go = (it) => { remember(it); input.value = ''; ghost.textContent = ''; close(); input.blur(); location.hash = it.href; };
  const rowFor = (it, i) => h('li', { class: `ps-row ${i === active ? 'active' : ''}`, role: 'option', onmousedown: (e) => e.preventDefault(), onclick: () => go(it) },
    it.team ? teamLogo(it.team, 30) : null,
    h('span', { class: 'ps-name' }, h('b', null, highlight(it.name, input.value)), h('small', null, it.sub)));

  // Grey completion text after what was typed: the top suggestion's name, accepted with Tab or the right arrow.
  function setGhost(q) {
    const top = items[0];
    if (!q || !top || fold(top.name).indexOf(fold(q)) !== 0 || fold(q).length !== q.length || top.name.length <= q.length) { ghost.textContent = ''; return; }
    ghost.replaceChildren(h('span', { style: { visibility: 'hidden' } }, q), top.name.slice(q.length));
  }

  function draw() {
    const q = input.value.trim();
    items = search(q);
    setGhost(input.value);
    if (!q) {
      // nothing typed yet: offer the recent picks
      const rec = recents();
      if (!rec.length || document.activeElement !== input) { close(); return; }
      items = rec; box.hidden = false;
      box.replaceChildren(h('ul', { role: 'listbox' }, h('li', { class: 'ps-note ps-recent-head' }, h('span', null, 'Recent'),
        h('button', { class: 'ps-clear', type: 'button', title: 'Clear recent searches', onmousedown: (e) => e.preventDefault(), onclick: (e) => { e.stopPropagation(); clearRecents(); draw(); } }, 'Clear')),
        items.map(rowFor)));
      return;
    }
    box.hidden = false;
    box.replaceChildren(h('ul', { role: 'listbox' }, items.length ? items.map(rowFor) : h('li', { class: 'ps-empty' }, q.length < 2 ? 'Keep typing…' : 'No matches')));
  }

  input.addEventListener('focus', draw);
  input.addEventListener('input', () => { active = -1; draw(); });
  input.addEventListener('blur', () => setTimeout(() => { close(); ghost.textContent = ''; }, 120));
  input.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (!items.length) return;
      active = (active + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      draw();
    } else if ((e.key === 'Tab' || e.key === 'ArrowRight') && ghost.textContent && input.selectionStart === input.value.length) {
      e.preventDefault();
      input.value = items[0].name; active = 0; draw();
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const it = items[active >= 0 ? active : 0];
      if (it) go(it);
    } else if (e.key === 'Escape') { input.value = ''; ghost.textContent = ''; close(); input.blur(); }
  });
  // "/" anywhere on the page (not while typing in a field) focuses the search box
  document.addEventListener('keydown', (e) => {
    if (e.key === '/' && document.activeElement === document.body) { e.preventDefault(); input.focus(); }
  });
  S.subscribe((t) => { if ((t.has('team') || t.has('teams')) && !box.hidden) draw(); });
}
