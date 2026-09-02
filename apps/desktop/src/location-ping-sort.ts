// Keeps Select Location ordered by measured latency without changing React state semantics.
// Countries with a known lower ping are shown first; unknown/unmeasured entries stay last.

const latencyValue = (node: Element | null): number => {
  if (!node) return Number.POSITIVE_INFINITY;
  const m = (node.textContent || '').match(/(\d+)\s*ms/i);
  return m ? Number(m[1]) : Number.POSITIVE_INFINITY;
};

const sortByLatency = () => {
  const list = document.querySelector('.country-list');
  if (!list) return;

  const countries = Array.from(list.querySelectorAll(':scope > .country-group'));
  countries.sort((a, b) => {
    const pa = latencyValue(a.querySelector(':scope > summary .country-latency'));
    const pb = latencyValue(b.querySelector(':scope > summary .country-latency'));
    if (pa !== pb) return pa - pb;
    const an = (a.querySelector(':scope > summary b')?.textContent || '').trim();
    const bn = (b.querySelector(':scope > summary b')?.textContent || '').trim();
    return an.localeCompare(bn);
  });
  for (const country of countries) list.appendChild(country);

  for (const country of countries) {
    const cities = country.querySelector('.location-list');
    if (!cities) continue;
    const rows = Array.from(cities.querySelectorAll(':scope > .location-row'));
    rows.sort((a, b) => {
      const pa = latencyValue(a.querySelector('.latency'));
      const pb = latencyValue(b.querySelector('.latency'));
      if (pa !== pb) return pa - pb;
      const an = (a.querySelector('.loc-main b')?.textContent || '').trim();
      const bn = (b.querySelector('.loc-main b')?.textContent || '').trim();
      return an.localeCompare(bn);
    });
    for (const row of rows) cities.appendChild(row);
  }
};

let queued = false;
const queueSort = () => {
  if (queued) return;
  queued = true;
  requestAnimationFrame(() => {
    queued = false;
    sortByLatency();
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
