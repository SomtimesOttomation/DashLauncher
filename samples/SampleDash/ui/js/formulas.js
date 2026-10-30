// Formula hover cards: every calculated number in the app can explain itself. Copied from NBADash's formulas.js.
// Mark any element with data-calc="<key>" (and optionally data-calc-scope="team"|"player"); hovering or focusing it shows
// the card. Add your own terms to DEFS: a title, the formula, and why it matters (NBADash has ~40, for every rating).
import { h } from './util.js';

// key -> (scope) => { title, formula, why, note? }
const DEFS = {
  gp: () => ({ title: 'Games played', formula: 'GP = games played so far', why: 'How many games the numbers next to it are based on. Early in the season small samples swing a lot.' }),
  pts: () => ({ title: 'Points', formula: 'PTS = 2 \u00d7 W + 1 \u00d7 OTL', why: 'Standings points: a win is worth 2, an overtime loss 1, a regulation loss 0.' }),
  ppct: () => ({ title: 'Points percentage', formula: 'P% = PTS / (2 \u00d7 GP)', why: 'Points earned out of points possible, so teams with games in hand compare fairly.' }),
  otl: () => ({ title: 'Overtime losses', formula: 'OTL = losses after regulation time', why: 'Worth 1 point in the standings, unlike a regulation loss.' }),
  diff: () => ({ title: 'Goal difference', formula: 'DIFF = Goals for \u2212 Goals against', why: 'How much a team outscores its opponents. A better sign of strength than the record when the record is close.' }),
  l10: () => ({ title: 'Last 10', formula: 'Record in the last 10 games (W-L-OTL)', why: 'Recent form, which the season record can hide.' }),
  pm: () => ({ title: 'Plus / Minus', formula: '+/- = Team goals \u2212 Opponent goals while on the ice', why: 'Straight from the box score. Noisy over small samples and heavily tied to teammates.' }),
  sog: () => ({ title: 'Shots on goal', formula: 'SOG = shots that reached the goalie or went in', why: 'Volume of real chances; a missed or blocked shot does not count.' }),
};

export const hasFormula = (key) => !!DEFS[key];

// Attributes to mark an element: h('span', { ...calc('drtg', 'team') }, 'DRtg')
export const calc = (key, scope = 'team') => (DEFS[key] ? { 'data-calc': key, 'data-calc-scope': scope, tabindex: 0, class: 'calc' } : {});

let tip = null;
function show(el) {
  const d = DEFS[el.dataset.calc]; if (!d) return;
  const c = d(el.dataset.calcScope || 'team');
  if (!tip) { tip = h('div', { class: 'calc-tip', role: 'tooltip' }); document.body.append(tip); }
  tip.replaceChildren(h('b', null, c.title), h('pre', null, c.formula), h('p', null, c.why), c.note ? h('small', null, c.note) : null);
  tip.style.display = 'block';
  const r = el.getBoundingClientRect(), tw = tip.offsetWidth, th = tip.offsetHeight;
  let x = Math.min(window.innerWidth - tw - 10, Math.max(10, r.left + r.width / 2 - tw / 2));
  let y = r.bottom + 8; if (y + th > window.innerHeight - 10) y = Math.max(10, r.top - th - 8);
  tip.style.left = `${x}px`; tip.style.top = `${y}px`;
}
const hide = () => { if (tip) tip.style.display = 'none'; };

export function installCalcTips() {
  document.addEventListener('mouseover', (e) => { const el = e.target.closest && e.target.closest('[data-calc]'); if (el) show(el); else hide(); });
  document.addEventListener('focusin', (e) => { const el = e.target.closest && e.target.closest('[data-calc]'); if (el) show(el); });
  document.addEventListener('focusout', hide);
  window.addEventListener('scroll', hide, true);
  window.addEventListener('hashchange', hide);
}
