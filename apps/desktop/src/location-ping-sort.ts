// Keeps Select Location ordered by measured latency without moving React-owned DOM nodes.
// Moving nodes with appendChild() breaks React's reconciliation order and can make a clicked
// country/city appear to select a different stale location. We only assign CSS order here.

const latencyValue = (node: Element | null): number => {
  if (!node) return Number.POSITIVE_INFINITY;
  const m = (node.textContent || '').match(/(\d+)\s*ms/i);
  return m ? Number(m[1]) : Number.POSITIVE_INFINITY;
};

const nameValue = (node: Element | null) => (node?.textContent || '').trim();

const applyLatencyOrder = () => {
  const list = document.querySelector<HTMLElement>('.country-list');
  if (!list) return;

  const countries = Array.from(list.querySelectorAll<HTMLElement>(':scope > .country-group'));
  const rankedCountries = [...countries].sort((a, b) => {
    const pa = latencyValue(a.querySelector(':scope > summary .country-latency'));
    const pb = latencyValue(b.querySelector(':scope > summary .country-latency'));
    if (pa !== pb) return pa - pb;
    return nameValue(a.querySelector(':scope > summary b')).localeCompare(nameValue(b.querySelector(':scope > summary b')));
  });
  rankedCountries.forEach((country, index) => { country.style.order = String(index); });

  for (const country of countries) {
    const cities = country.querySelector<HTMLElement>('.location-list');
    if (!cities) continue;
    const rows = Array.from(cities.querySelectorAll<HTMLElement>(':scope > .location-row'));
    const rankedRows = [...rows].sort((a, b) => {
      const pa = latencyValue(a.querySelector('.latency'));
      const pb = latencyValue(b.querySelector('.latency'));
      if (pa !== pb) return pa - pb;
      return nameValue(a.querySelector('.loc-main b')).localeCompare(nameValue(b.querySelector('.loc-main b')));
    });
    rankedRows.forEach((row, index) => { row.style.order = String(index); });
  }
};

let queued = false;
const queueSort = () => {
  if (queued) return;
  queued = true;
  requestAnimationFrame(() => {
    queued = false;
    applyLatencyOrder();
  });
};

const observer = new MutationObserver(queueSort);
observer.observe(document.documentElement, {
  childList: true,
  subtree: true,
  characterData: true,
});

window.addEventListener('DOMContentLoaded', queueSort);
queueSort();
