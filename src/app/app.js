const post = m => window.ipc.postMessage(JSON.stringify(m));
// Reports phase timings (ms since page start) to the backend for the bench.
const ready = t => post({ type: 'mark', ...t });

// Backend → page events arrive in batches of {v, req, type, data}; handlers are keyed by request ID.
window.griiy = {
  handlers: new Map(),
  recv(batch) { for (const m of batch) this.handlers.get(m.req)?.(m); },
  cancel(req) { this.handlers.delete(req); post({ type: 'cancel', req }); },
};

const esc = s => s.replace(/[&<>"]/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;' }[c]));

function showError({ title, detail, hint }) {
  document.getElementById('repo').textContent = 'griiy';
  document.getElementById('diff').innerHTML =
    `<div class="error"><h1>${esc(title)}</h1>${detail ? `<pre>${esc(detail)}</pre>` : ''}<p>${esc(hint)}</p></div>`;
}

// Split unified diff text into [{ name, add, del, lines }].
function parse(text) {
  const files = [];
  let f = null;
  for (const line of text.split('\n')) {
    if (line.startsWith('diff --git ')) {
      f = { name: line.split(' b/').pop(), add: 0, del: 0, lines: [] };
      files.push(f);
    } else if (f && !/^(index |--- |\+\+\+ |new file|deleted file|similarity|rename |old mode|new mode)/.test(line)) {
      if (line[0] === '+') f.add++; else if (line[0] === '-') f.del++;
      f.lines.push(line);
    }
  }
  return files;
}

// Nest paths into { d: Map(dir -> node), f: [path] }.
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

// Returns [html, containsChange]. Single-child dir chains collapse to "a/b/c";
// dirs holding a changed file start open.
function renderTree(n, changed) {
  let html = '', hot = false;
  for (let [name, c] of [...n.d].sort(([a], [b]) => a < b ? -1 : 1)) {
    while (!c.f.length && c.d.size === 1) { const [[k, v]] = c.d; name += '/' + k; c = v; }
    const [inner, h] = renderTree(c, changed);
    hot ||= h;
    html += `<details${h ? ' open' : ''}><summary>${esc(name)}</summary>${inner}</details>`;
  }
  for (const p of n.f.sort()) {
    const f = changed.get(p), base = esc(p.slice(p.lastIndexOf('/') + 1));
    if (f) hot = true;
    html += f
      ? `<a href="#f${f.i}"><span>${base}</span><small><span class="a">+${f.add}</span> <span class="d">-${f.del}</span></small></a>`
      : `<a class="un"><span>${base}</span></a>`;
  }
  return [html, hot];
}

const cls = l => l[0] === '+' ? 'ad' : l[0] === '-' ? 'de' : l.startsWith('@@') ? 'hu' : '';

(async () => {
  const t0 = performance.now();
  post({ type: 'ready' });
  const { review, error } = window.__GRIIY__;
  if (error) { showError(error); return requestAnimationFrame(() => setTimeout(() => ready({ error: error.title }))); }
  const { repo, label, head, text, tracked, gitMs } = review;
  const t1 = performance.now();
  const files = parse(text);
  document.getElementById('repo').textContent = repo;
  const all = tracked.split('\n').filter(Boolean);
  document.getElementById('src').textContent = `${label} · ${files.length} changed / ${all.length} files`;
  const changed = new Map(files.map((f, i) => [f.name, { ...f, i }]));
  // Deleted files aren't in ls-files but still belong in the tree.
  document.getElementById('files').innerHTML = renderTree(buildTree(new Set([...all, ...changed.keys()])), changed)[0];
  document.getElementById('diff').innerHTML = files.length ? files.map((f, i) =>
    `<section id="f${i}"><h2>${esc(f.name)}</h2><pre>${
      f.lines.map(l => `<div class="${cls(l)}">${esc(l)}</div>`).join('')}</pre></section>`).join('')
    : `<p class="empty">No changes.${head === 'worktree' ? ' To see the last commit: griiy HEAD~1..HEAD' : ''}</p>`;
  document.getElementById('files').onclick = e => {
    const a = e.target.closest('a[href]'); if (!a) return;
    document.querySelectorAll('nav a.on').forEach(x => x.classList.remove('on'));
    a.classList.add('on');
  };
  const t2 = performance.now();
  requestAnimationFrame(() => setTimeout(() => ready({
    page: Math.round(t0), git: gitMs, data: Math.round(t1 - t0), render: Math.round(performance.now() - t1),
    dom: Math.round(t2 - t1), lines: text.split('\n').length, files: all.length })));
})();
