import { createRenderer, withoutFrontmatter } from './renderer.js';
import DOMPurify from 'dompurify';
import mermaid from 'mermaid';
const md = createRenderer(), root = document.getElementById('minutes');
mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'base',
  themeVariables: { primaryColor: '#ede0cd', primaryTextColor: '#221f1c', primaryBorderColor: '#6b6157', lineColor: '#6b6157', fontFamily: '-apple-system, sans-serif' },
  htmlLabels: false, flowchart: { htmlLabels: false }, maxTextSize: 100000, maxEdges: 1000,
  suppressErrorRendering: true });
let generation = 0, query = '', hit = -1, ranges = [], source = '', context = '';
let updateListeners = new AbortController();
const report = value => window.webkit?.messageHandlers.minutes.postMessage(value);
const safeHTML = value => DOMPurify.sanitize(value, { ADD_TAGS: ['eq', 'eqn'], ADD_URI_SAFE_ATTR: ['data-wiki'],
  ADD_ATTR: ['data-heading', 'data-kind'], ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|minutes-image):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i });

function nodes() {
  const all = [], walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: node => node.parentElement.closest('script,style,.katex-mathml,annotation') ||
      (node.parentElement === root && !node.textContent.trim()) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
  });
  while (walker.nextNode()) all.push(walker.currentNode);
  return all;
}
function point(offset) {
  const all = nodes();
  for (const node of all) {
    if (offset <= node.length) return [node, offset];
    offset -= node.length;
  }
  return all.length ? [all.at(-1), all.at(-1).length] : [root, 0];
}
function selectionOffsets() {
  const selection = getSelection();
  if (!selection.rangeCount || !root.contains(selection.anchorNode) || !root.contains(selection.focusNode)) return null;
  const range = selection.getRangeAt(0), all = nodes();
  let total = 0, start = 0, end = 0;
  for (const node of all) {
    if (node === range.startContainer) start = total + range.startOffset;
    if (node === range.endContainer) end = total + range.endOffset;
    total += node.length;
  }
  return [start, end];
}
function restoreSelection(value) {
  if (!value) { getSelection().removeAllRanges(); return; }
  const range = document.createRange();
  range.setStart(...point(value[0])); range.setEnd(...point(value[1]));
  getSelection().removeAllRanges(); getSelection().addRange(range);
}
function anchor() {
  const elements = [...root.children];
  const at = elements.findIndex(el => el.getBoundingClientRect().bottom > 0);
  return { at, text: elements[at]?.textContent, y: elements[at]?.getBoundingClientRect().top || 0, scroll: scrollY };
}
function restoreAnchor(saved) {
  if (!saved || saved.scroll === 0) { scrollTo(0, 0); return; }
  const elements = [...root.children];
  const el = elements.find(el => el.textContent === saved.text) || elements[Math.min(saved.at, elements.length - 1)];
  if (el) scrollTo(0, scrollY + el.getBoundingClientRect().top - saved.y);
}
function refreshSearch(reveal = false) {
    ranges = [];
    if (query) {
    // 元のUTF-16位置を保ったまま大文字小文字を無視する。入力の正規表現記号はすべて引用する。
    // 毎ヒットでDOM全体を歩かず、文字位置の索引を二分探索する。
    let text = '', previousBlock;
    const index = nodes().map(node => {
      const block = node.parentElement.closest('p,li,td,th,h1,h2,h3,h4,h5,h6,pre,.callout-title');
      if (previousBlock && block !== previousBlock) text += '\n';
      previousBlock = block;
      const start = text.length; text += node.textContent;
      return { node, start, end: text.length };
    });
    const position = offset => {
      let low = 0, high = index.length - 1;
      while (low < high) { const mid = (low + high) >> 1; if (index[mid].end < offset) low = mid + 1; else high = mid; }
      const entry = index[low]; return [entry.node, Math.max(0, Math.min(entry.node.length, offset - entry.start))];
    };
    const pattern = new RegExp(query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'giu');
    for (const match of text.matchAll(pattern)) {
      const range = document.createRange(); range.setStart(...position(match.index)); range.setEnd(...position(match.index + match[0].length));
      ranges.push(range);
      if (ranges.length >= 10000) break;
    }
  }
  hit = ranges.length ? Math.min(Math.max(hit, 0), ranges.length - 1) : -1;
  paint(reveal); return { count: ranges.length, current: hit + 1 };
}
function paint(reveal) {
  CSS.highlights.set('matches', new Highlight(...ranges));
  CSS.highlights.set('current', new Highlight(...(hit >= 0 ? [ranges[hit]] : [])));
  if (reveal && hit >= 0) {
    const rect = ranges[hit].getBoundingClientRect();
    scrollTo(0, Math.max(0, scrollY + rect.top - innerHeight / 3));
  }
}
window.minutes = {
  async render(text, newContext, reset, ticket) {
    const current = ++generation;
    updateListeners.abort(); updateListeners = new AbortController();
    const saved = reset ? null : anchor(), selection = reset ? null : selectionOffsets();
    source = text; context = newContext;
    root.innerHTML = safeHTML(md.render(withoutFrontmatter(text), { context }));
    for (const pre of [...root.querySelectorAll('.svg-source')]) {
      const clean = DOMPurify.sanitize(pre.textContent, { USE_PROFILES: { svg: true, svgFilters: true },
        FORBID_TAGS: ['foreignObject', 'script', 'image', 'use', 'a', 'style', 'animate', 'set'],
        FORBID_ATTR: ['href', 'xlink:href', 'style'] });
      if (!clean.startsWith('<svg')) continue;
      const image = new Image(); image.alt = 'SVG図';
      image.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(clean);
      pre.replaceWith(image);
    }
    // 画像要求が即完了しても取りこぼさないよう、図の非同期描画より前に登録する。
    let restore = true;
    const stop = () => { restore = false; };
    addEventListener('wheel', stop, { once: true, passive: true, signal: updateListeners.signal });
    addEventListener('pointerdown', stop, { once: true, signal: updateListeners.signal });
    addEventListener('keydown', stop, { once: true, signal: updateListeners.signal });
    for (const image of root.querySelectorAll('img')) {
      const loaded = () => { if (restore && current === generation) restoreAnchor(saved); };
      const failed = () => {
        if (current !== generation || !image.isConnected) return;
        const fallback = document.createElement('span'); fallback.className = 'image-error';
        fallback.textContent = '画像を表示できません: ' + image.alt; image.replaceWith(fallback);
        if (restore) restoreAnchor(saved);
        refreshSearch(false);
      };
      image.addEventListener('load', loaded, { once: true, signal: updateListeners.signal });
      image.addEventListener('error', failed, { once: true, signal: updateListeners.signal });
      if (image.complete) { if (image.naturalWidth) loaded(); else failed(); }
    }
    restoreAnchor(saved); restoreSelection(selection); refreshSearch();
    for (const pre of [...root.querySelectorAll('.mermaid-source')]) {
      if (current !== generation) return;
      const holder = document.createElement('div'); holder.className = 'diagram';
      try {
        const { svg } = await mermaid.render('diagram-' + current + '-' + crypto.randomUUID(), pre.textContent);
        if (current !== generation) return;
        holder.innerHTML = DOMPurify.sanitize(svg, { USE_PROFILES: { svg: true, svgFilters: true }, FORBID_TAGS: ['foreignObject', 'script', 'a'] });
        pre.replaceWith(holder);
      } catch { pre.title = '図を描画できないため、記法を表示しています'; }
    }
    if (current !== generation) return;
    if (restore) { restoreAnchor(saved); restoreSelection(selection); }
    refreshSearch();
    report({ kind: 'rendered', ticket, text: root.innerText });
    return true;
  },
  clear() { generation++; updateListeners.abort(); source = ''; root.replaceChildren(); query = ''; refreshSearch(); scrollTo(0, 0); },
  invalidate() { generation++; updateListeners.abort(); },
  search(value, direction = 0, reveal = true) {
    if (query !== value) { query = value; hit = 0; return refreshSearch(reveal); }
    if (ranges.length && direction) hit = (hit + direction + ranges.length) % ranges.length;
    paint(reveal); return { count: ranges.length, current: hit + 1 };
  },
  state() { return { text: root.innerText, width: root.getBoundingClientRect().width, scroll: scrollY, selection: selectionOffsets(), html: root.innerHTML }; },
  select(start, end) { restoreSelection([start, end]); },
};
root.addEventListener('pointerdown', () => report({ kind: 'focus' }));
root.addEventListener('click', event => {
  const link = event.target.closest('a'); if (!link) return;
  event.preventDefault();
  const href = link.getAttribute('href') || '';
  if (href.startsWith('#')) {
    const name = decodeURIComponent(href.slice(1));
    const target = document.getElementById(name) || document.getElementById('heading-' + name) ||
      [...root.querySelectorAll('[data-heading]')].find(el => el.dataset.heading === name);
    target?.scrollIntoView({ block: 'start' }); return;
  }
  report({ kind: 'link', href });
});
report({ kind: 'ready' });
