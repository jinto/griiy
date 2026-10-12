const post = m => window.ipc.postMessage(JSON.stringify(m));
// Reports phase timings (ms since page start) to the backend for the bench.
const ready = t => post({ type: 'mark', wall: Date.now(), ...t }); // wall: epoch ms, for the bench's launch→paint

// Backend → page events arrive in batches of {v, req, type, data}; handlers are keyed by request ID.
window.griiy = {
  handlers: new Map(),
  recv(batch) { for (const m of batch) this.handlers.get(m.req)?.(m); },
  cancel(req) { this.handlers.delete(req); post({ type: 'cancel', req }); },
};

const esc = s => s.replace(/[&<>"]/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;' }[c]));
const $ = id => document.getElementById(id);
const api = path => fetch(`griiy://api/${path}`).then(r => r.ok ? r.json() : Promise.reject(r.status));

function showError({ title, detail, hint }) {
  $('repo').textContent = 'griiy';
  $('diff').innerHTML =
    `<div class="error"><h1>${esc(title)}</h1>${detail ? `<pre>${esc(detail)}</pre>` : ''}<p>${esc(hint)}</p></div>`;
}

// ---- Diff panel: a virtual list of fixed-height rows (PLAN-M1-5-6) ----
// Every file is `rows` rows tall (header, hunk headers, lines; the backend counts them), so the
// whole scroll height and each file's first row are known before any diff loads. Only the rows
// in view, plus one screen either side, are in the DOM. Rows load in chunks on first sight, so
// even a 120k-line file is never in memory whole.

const H = 18; // px, the `.r` height in app.css
const CHUNK = 1000; // rows per api/diff request
// ponytail: LRU by chunk count; tune if RSS or refetching shows up in bench. The bench lowers it
// so eviction actually runs.
let cacheChunks = 50, evicted = 0;
let files = [], start = [], total = 0;
const cache = new Map(), pending = new Set(), seen = new Set(); // cache keys: `${file}/${chunk}`
const prefill = new Map(); // first rows of a file that came cut short with the review
let drawn = new Set(), blank = false, queued = false, widest = 0;

/// Index of the file holding global row r (binary search over first rows).
function fileAt(r) {
  let lo = 0, hi = files.length - 1;
  while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (start[mid] <= r) lo = mid; else hi = mid - 1; }
  return lo;
}

function load(key, i, c) {
  if (pending.has(key)) return;
  pending.add(key);
  api(`diff?id=${i}&from=${c * CHUNK}&n=${CHUNK}`).then(v => v.rows, e => [['n', `Could not load these rows (${e}).`]])
    .then(rows => {
      // A failure is cached too: the data is in memory, so retrying would fail the same way.
      pending.delete(key); seen.add(i);
      cache.set(key, rows);
      schedule();
    });
}

/// Drops least recently drawn chunks, never the ones on screen.
function evict() {
  for (const key of cache.keys()) {
    if (cache.size <= cacheChunks) break;
    if (!drawn.has(key)) { cache.delete(key); evicted++; }
  }
}

const STATUS = { added: 'A', deleted: 'D', modified: 'M', renamed: 'R', copied: 'C' };
function header(f) {
  const from = f.oldPath ? `<span class="from">${esc(f.oldPath)} → </span>` : '';
  return `<span class="st ${f.status}">${STATUS[f.status]}</span>${from}${esc(f.path)}` +
    `<small><span class="a">+${f.add}</span> <span class="d">-${f.del}</span></small>`;
}

const LINE = { ' ': '', '+': 'ad', '-': 'de' };
function row(r) {
  const f = files[fileAt(r)], k = r - start[f.i];
  if (k === 0) return `<div class="r fh" data-r="${r}">${header(f)}</div>`;
  const c = Math.floor(k / CHUNK), key = `${f.i}/${c}`, chunk = cache.get(key);
  if (chunk) drawn.add(key);
  const x = chunk ? chunk[k % CHUNK] : prefill.get(f.i)?.[k];
  if (!x) {
    // Loads only when a row is actually missing, so a file that came cut short with the review
    // loads once it's scrolled past its first screen. A failed chunk just ends early.
    if (!chunk) { blank = true; load(key, f.i, c); }
    return `<div class="r" data-r="${r}"></div>`;
  }
  switch (x[0]) {
    case 'h': return `<div class="r hu" data-r="${r}">${esc(x[1])}</div>`;
    case 'n': return `<div class="r note" data-r="${r}">${esc(x[1])}</div>`;
    default: return `<div class="r ${LINE[x[0]]}${x[4] ? ' nn' : ''}" data-r="${r}"><i data-o="${x[1] ?? ''}" ` +
      `data-n="${x[2] ?? ''}"></i>${esc(x[3])}</div>`;
  }
}

function render() {
  queued = false;
  const main = $('diff'), top = main.scrollTop, view = main.clientHeight;
  const first = Math.max(0, Math.floor(top / H) - Math.ceil(view / H));
  const last = Math.min(total, Math.ceil((top + 2 * view) / H));
  drawn = new Set(); blank = false;
  let html = '';
  for (let r = first; r < last; r++) html += row(r);
  // Chunks just drawn move to the back of the LRU order.
  for (const key of drawn) { const rows = cache.get(key); cache.delete(key); cache.set(key, rows); }
  evict();
  const list = $('rows');
  list.style.transform = `translateY(${first * H}px)`;
  list.innerHTML = html;
  // Width only grows, so the horizontal scrollbar doesn't jump as long lines come and go.
  if (list.scrollWidth > widest) { widest = list.scrollWidth; list.style.minWidth = `${widest}px`; }
  $('sticky').firstChild.innerHTML = header(files[fileAt(Math.floor(top / H))]);
}

// Scroll, resize, arriving rows and tree clicks all render at most once per frame. A late response
// for a file no longer on screen costs one render that draws nothing new.
const schedule = () => { if (!queued) { queued = true; requestAnimationFrame(render); } };

// ---- File tree (F-DV-1): folders with no change start closed and empty, filled when opened ----

/// Nest paths into { d: Map(dir -> node), f: [path] }.
function buildTree(paths) {
  const root = { d: new Map(), f: [] };
  for (const p of paths) {
    let n = root;
    for (const s of p.split('/').slice(0, -1)) {
      if (!n.d.has(s)) n.d.set(s, { d: new Map(), f: [] });
      n = n.d.get(s);
    }
    n.f.push(p);
  }
  return root;
}

const closed = []; // tree nodes behind closed, still-empty <details>, by data-k

/// Single-child dir chains collapse to "a/b/c"; dirs holding a changed file start open.
function renderTree(n, prefix, changed, hot) {
  let html = '';
  for (let [name, c] of [...n.d].sort(([a], [b]) => a < b ? -1 : 1)) {
    while (!c.f.length && c.d.size === 1) { const [[k, v]] = c.d; name += '/' + k; c = v; }
    const path = prefix + name + '/';
    html += hot.has(path)
      ? `<details open><summary>${esc(name)}</summary>${renderTree(c, path, changed, hot)}</details>`
      : `<details data-k="${closed.push([c, path]) - 1}"><summary>${esc(name)}</summary></details>`;
  }
  for (const p of n.f.sort()) {
    const f = changed.get(p), base = esc(p.slice(p.lastIndexOf('/') + 1));
    html += f
      ? `<a data-i="${f.i}" href="#"><span>${base}</span><small><span class="a">+${f.add}</span> <span class="d">-${f.del}</span></small></a>`
      : `<a class="un"><span>${base}</span></a>`;
  }
  return html;
}

function showTree(tracked, label) {
  const changed = new Map(files.map(f => [f.path, f]));
  // Deleted files aren't in ls-files but still belong in the tree.
  const all = new Set([...tracked.split('\n').filter(Boolean), ...changed.keys()]);
  const hot = new Set();
  for (const p of changed.keys()) for (let j = p.indexOf('/'); j > 0; j = p.indexOf('/', j + 1)) hot.add(p.slice(0, j + 1));
  const nav = $('files');
  nav.innerHTML = renderTree(buildTree(all), '', changed, hot);
  $('src').textContent = `${label} · ${files.length} changed / ${all.size} files`;
  nav.addEventListener('toggle', e => {
    const d = e.target, k = d.dataset.k;
    if (!d.open || k === undefined) return;
    const [node, path] = closed[k];
    delete d.dataset.k;
    d.insertAdjacentHTML('beforeend', renderTree(node, path, changed, hot));
  }, true); // toggle doesn't bubble
  nav.onclick = e => {
    const a = e.target.closest('a[data-i]'); if (!a) return;
    e.preventDefault();
    nav.querySelectorAll('a.on').forEach(x => x.classList.remove('on'));
    a.classList.add('on');
    $('diff').scrollTop = start[a.dataset.i] * H;
  };
}

// ---- Bench (only under bench.sh): jump to 10 points (a scrollbar drag), and from each scroll
// half a screen per frame for 60 frames (a fast wheel). Scrolling the whole 2.6M px of a 120k-line
// diff this way would take minutes. ----

async function autoscroll() {
  const main = $('diff'), gaps = [];
  let domMax = 0, blanks = 0;
  for (let k = 0; k < 10; k++) {
    // k/10, not k/9: the last segment must still have room to scroll.
    main.scrollTop = (main.scrollHeight - main.clientHeight) * k / 10;
    let prev, n = 0;
    await new Promise(done => requestAnimationFrame(function step(ts) {
      // The first gap after a jump is the jump itself, not scrolling.
      if (prev !== undefined && n > 1) gaps.push(ts - prev);
      prev = ts;
      domMax = Math.max(domMax, main.getElementsByTagName('*').length);
      if (blank && n > 1) blanks++;
      if (++n > 60) return done();
      main.scrollTop += main.clientHeight / 2; // renders through the real scroll event path
      requestAnimationFrame(step);
    }));
  }
  const median = [...gaps].sort((a, b) => a - b)[gaps.length >> 1] ?? 0;
  ready({ scroll: { frames: gaps.length, long: gaps.filter(x => x > 50).length, max: Math.round(Math.max(0, ...gaps)),
    median: Math.round(median), throttled: median > 20, domMax, blank: blanks, loaded: seen.size, files: files.length,
    cached: cache.size, evicted } });
}

(async () => {
  const t0 = performance.now();
  const { bench } = window.__GRIIY__;
  // git runs while the page loads; the result arrives on the event channel as request 0.
  const { review, error } = await new Promise(done => {
    window.griiy.handlers.set(0, m => done({ [m.type]: m.data }));
    post({ type: 'ready' });
  });
  if (error) {
    showError(error);
    return requestAnimationFrame(() => setTimeout(() => { ready({ error: error.title }); if (bench) ready({ scroll: null }); }));
  }
  const { repo, label, head, gitMs } = review;
  $('repo').textContent = repo;
  $('src').textContent = `${label} · ${review.files.length} changed`;
  files = review.files.map(([path, status, add, del, rows, oldPath, binary], i) =>
    ({ i, path, status, add, del, rows, oldPath, binary }));
  for (const f of files) { start.push(total); total += f.rows; }
  review.first.forEach((rows, i) => {
    if (rows.length < files[i].rows) return prefill.set(i, rows); // drawn now, loaded on sight
    cache.set(`${i}/0`, rows); seen.add(i); // under 300 rows: the whole file is its first chunk
  });
  const t1 = performance.now();
  const main = $('diff');
  if (!files.length) {
    main.innerHTML = `<p class="empty">No changes.${head === 'worktree' ? ' To see the last commit: griiy HEAD~1..HEAD' : ''}</p>`;
  } else {
    // ponytail: past ~16M px (~900k rows) WebKit caps element height; the fix is a scaled spacer
    // mapping scrollTop to rows proportionally (PLAN R11).
    main.innerHTML = '<div id="sticky"><div class="r fh"></div></div><div id="space"><div id="rows"></div></div>';
    $('space').style.height = `${total * H}px`;
    main.addEventListener('scroll', schedule, { passive: true });
    addEventListener('resize', schedule);
    if (bench) cacheChunks = 10;
    render();
  }
  // First paint is when the rows on screen have arrived, not just their headers.
  while (blank) await new Promise(r => requestAnimationFrame(r));
  const t2 = performance.now();
  requestAnimationFrame(() => setTimeout(async () => {
    ready({ page: Math.round(t0), git: gitMs, data: Math.round(t1 - t0), render: Math.round(t2 - t1),
      rows: total, files: files.length, dom: main.getElementsByTagName('*').length });
    api('tracked').then(v => showTree(v.tracked, label), () => showTree('', label));
    if (bench && files.length) await autoscroll(); else if (bench) ready({ scroll: null });
  }));
})();
