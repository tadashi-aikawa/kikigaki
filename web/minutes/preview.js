import { createRenderer, withoutFrontmatter } from './renderer.js';
import DOMPurify from 'dompurify';
import mermaid from 'mermaid';
import { cleanHTML } from './html.js';
import { changedEntries, updateEntries, clearUpdates, highlightUpdates } from './updates.js';
import { isTimeline, wrapTimeline } from './timeline.js';
const md = createRenderer(), root = document.getElementById('minutes');
const toc = document.getElementById('toc'), tocNav = toc.querySelector('nav');
let headings = [], tocLinks = [], activeTOCLink = null, tocFrame = 0;
let folded = new Set();
function prepareSections(reset) {
  if (reset) folded.clear();
  const used = new Set();
  root.querySelectorAll('h1,h2,h3,h4,h5,h6').forEach((heading, i) => {
    let id = heading.id || 'heading-html-' + (heading.textContent.trim().toLowerCase().replace(/\s+/g, '-') || i);
    while (used.has(id)) id += '-duplicate';
    heading.id = id; used.add(id);
  });
  folded = new Set([...folded].filter(id => used.has(id)));
  // 同じ親にある見出しを段数で組む。引用やcalloutの外まで巻き込まない。
  const parents = new Set([...root.querySelectorAll('h1,h2,h3,h4,h5,h6')].map(h => h.parentElement));
  for (const parent of parents) {
    const children = [...parent.childNodes], stack = [];
    for (const child of children) {
      if (/^H[1-6]$/.test(child.nodeName)) {
        const level = Number(child.tagName.slice(1));
        while (stack.length && stack.at(-1).level >= level) stack.pop();
        const section = document.createElement('section'); section.className = 'heading-section';
        const body = document.createElement('div'); body.className = 'section-body';
        body.id = 'section-' + child.id;
        if (stack.length) stack.at(-1).body.append(section); else parent.insertBefore(section, child);
        section.append(child, body);
        const button = document.createElement('button'); button.className = 'heading-toggle';
        button.type = 'button'; button.setAttribute('aria-controls', body.id);
        button.setAttribute('aria-label', child.textContent + 'を折りたたみ・展開');
        button.textContent = '▾'; child.prepend(button);
        const closed = folded.has(child.id); body.hidden = closed;
        button.setAttribute('aria-expanded', String(!closed));
        button.addEventListener('click', () => {
          body.hidden = !body.hidden;
          button.setAttribute('aria-expanded', String(!body.hidden));
          if (body.hidden) folded.add(child.id); else folded.delete(child.id);
          updateTOCPosition();
        });
        stack.push({ level, body });
      } else if (stack.length) stack.at(-1).body.append(child);
    }
  }
}
function revealElement(element) {
  for (let parent = element; parent && parent !== root; parent = parent.parentElement) {
    if (parent.classList.contains('section-body') && parent.hidden) {
      parent.hidden = false;
      const heading = parent.previousElementSibling;
      heading.querySelector('.heading-toggle').setAttribute('aria-expanded', 'true');
      folded.delete(heading.id);
    }
    if (parent.tagName === 'DETAILS') parent.open = true;
  }
}
let landingAnimation, navigationFrame = null, landedTOC = null;
function cancelNavigation() {
  if (navigationFrame !== null) cancelAnimationFrame(navigationFrame);
  navigationFrame = null; landedTOC = null;
  landingAnimation?.cancel();
}
function highlightLanding(target, duration) {
  landingAnimation?.cancel();
  landingAnimation = target.animate([
    { backgroundColor:'#9b72c650', boxShadow:'0 0 0 3px #9b72c630' },
    { backgroundColor:'#9b72c650', boxShadow:'0 0 0 3px #9b72c630', offset:0.5 },
    { backgroundColor:'transparent', boxShadow:'0 0 0 3px transparent' },
  ], { duration });
}
function jumpTo(element) {
  if (!element || !root.contains(element)) return;
  cancelNavigation();
  revealElement(element);
  element.scrollIntoView({ block:'center' });
  highlightLanding(element.closest('.footnote-ref') || element, 2000);
}
function navigateTOC(target) {
  cancelNavigation();
  revealElement(target);
  const start = scrollY;
  const end = Math.max(0, Math.min(start + target.getBoundingClientRect().top,
    document.scrollingElement.scrollHeight - innerHeight));
  const finish = () => {
    navigationFrame = null;
    landedTOC = { target, y:scrollY };
    updateTOCPosition();
    highlightLanding(target, 1000);
  };
  if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
    scrollTo(0, end); finish(); return;
  }
  // ブラウザ任せのsmoothでは移動距離で所要時間が変わる。経過時間で0.25秒のease-outに揃える。
  let started;
  const step = timestamp => {
    if (!root.contains(target)) { cancelNavigation(); return; }
    started ??= timestamp;
    const progress = Math.min(1, Math.max(0, (timestamp - started) / 250));
    scrollTo(0, start + (end - start) * (1 - (1 - progress) ** 3));
    if (progress < 1) navigationFrame = requestAnimationFrame(step);
    else finish();
  };
  navigationFrame = requestAnimationFrame(step);
}
function updateTOCPosition() {
  tocFrame = 0;
  if (!toc.open) return;
  let current = null;
  // 折りたたまれた見出しは位置を持たない。上限300件の表示中の見出しだけを調べる。
  for (let i = 0; i < headings.length; i++) {
    if (!headings[i].getClientRects().length) continue;
    if (headings[i].getBoundingClientRect().top > 80) break;
    current = tocLinks[i];
  }
  // 文末など上端に揃えられない見出しも着地先を示す。スクロールやレイアウト変更で外れたら位置追従へ戻す。
  const landedTop = landedTOC?.target.getBoundingClientRect().top;
  if (landedTOC && Math.abs(scrollY - landedTOC.y) < 1 && landedTOC.target.getClientRects().length &&
      landedTop >= 0 && landedTop < innerHeight) {
    current = tocLinks[headings.indexOf(landedTOC.target)];
  } else landedTOC = null;
  if (current === activeTOCLink) return;
  activeTOCLink?.removeAttribute('aria-current');
  current?.setAttribute('aria-current', 'location'); activeTOCLink = current;
}
function rebuildTOC(reset) {
  const allHeadings = root.querySelectorAll('h1,h2,h3,h4,h5,h6');
  headings = Array.from(allHeadings).slice(0, 300);
  toc.hidden = headings.length === 0;
  if (reset || toc.hidden) toc.open = false;
  activeTOCLink = null;
  const base = headings.reduce((level, heading) => Math.min(level, Number(heading.tagName.slice(1))), 6);
  tocLinks = headings.map(heading => {
    const link = document.createElement('a');
    link.href = '#' + encodeURIComponent(heading.id); link.dataset.target = heading.id;
    const label = heading.cloneNode(true);
    label.querySelectorAll('.katex-mathml,.heading-toggle').forEach(node => node.remove());
    link.textContent = label.textContent;
    link.style.setProperty('--depth', Number(heading.tagName.slice(1)) - base);
    return link;
  });
  tocNav.replaceChildren(...tocLinks);
  // 閉じているdetailsは測れないため、独立した不可視の測定用navを置く。
  const measure = tocNav.cloneNode(true); measure.className = 'toc-measure';
  document.body.append(measure);
  toc.style.width = Math.ceil(Math.max(100, measure.getBoundingClientRect().width + 14)) + 'px';
  measure.remove();
  if (allHeadings.length > headings.length) {
    const note = document.createElement('p'); note.textContent = '目次は先頭300見出しまで表示しています';
    tocNav.append(note);
  }
  updateTOCPosition();
}
addEventListener('scroll', () => { if (!tocFrame) tocFrame = requestAnimationFrame(updateTOCPosition); }, { passive:true });
addEventListener('resize', () => { if (!tocFrame) tocFrame = requestAnimationFrame(updateTOCPosition); });
for (const type of ['wheel', 'keydown', 'touchstart']) {
  addEventListener(type, cancelNavigation, { passive:true });
}
toc.addEventListener('pointerdown', () => report({ kind: 'focus' }));
toc.addEventListener('toggle', () => { if (toc.open) updateTOCPosition(); });
tocNav.addEventListener('click', event => {
  const link = event.target.closest('a'); if (!link) return;
  event.preventDefault();
  const target = document.getElementById(link.dataset.target);
  if (target) navigateTOC(target);
});
mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: 'base', fontFamily: '-apple-system, sans-serif',
  themeVariables: { primaryColor: '#ede0cd', primaryTextColor: '#221f1c', primaryBorderColor: '#6b6157', lineColor: '#6b6157', fontFamily: '-apple-system, sans-serif' },
  htmlLabels: false, flowchart: { htmlLabels: false }, mindmap: { maxNodeWidth: 320 }, maxTextSize: 100000, maxEdges: 1000,
  suppressErrorRendering: true });
// timelineの枠は150px固定(Mermaidの内部値)。描画と同じ16pxの書体で測り、端の余裕として4%残す。
const timelineMeasure = document.createElement('canvas').getContext('2d');
const fitsTimelineNode = text => {
  timelineMeasure.font = '16px -apple-system, sans-serif';
  return timelineMeasure.measureText(text).width <= 144;
};
let generation = 0, query = '', hit = -1, ranges = [], source = '', context = '';
let lastUpdateEntries = null;
let updateListeners = new AbortController();
const report = value => window.webkit?.messageHandlers.minutes.postMessage(value);
const safeHTML = value => DOMPurify.sanitize(value, { ADD_TAGS: ['eq', 'eqn'], ADD_URI_SAFE_ATTR: ['data-wiki'],
  ADD_ATTR: ['data-heading', 'data-kind'], ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|minutes-image):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i });

function nodes() {
  const all = [], walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: node => node.parentElement.closest('script,style,.katex-mathml,annotation,.heading-toggle') ||
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
function blocks() {
  return [...root.querySelectorAll(':scope > :not(.heading-section), .section-body > :not(.heading-section), .heading-section > :is(h1,h2,h3,h4,h5,h6)')];
}
function signature(element) {
  if (!element) return '';
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let result = '';
  while (result.length < 120 && walker.nextNode()) result += walker.currentNode.textContent.slice(0, 120 - result.length);
  return element.tagName + ':' + result;
}
function anchor() {
  const elements = blocks();
  const at = elements.findIndex(el => el.getClientRects().length && el.getBoundingClientRect().bottom > 0);
  return { at, text: signature(elements[at]), y: elements[at]?.getBoundingClientRect().top || 0, scroll: scrollY };
}
function restoreAnchor(saved) {
  if (!saved || saved.scroll === 0) { scrollTo(0, 0); return; }
  const elements = blocks();
  const el = elements.find(el => signature(el) === saved.text && el.getClientRects().length) || elements[Math.min(saved.at, elements.length - 1)];
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
  cancelNavigation();
  CSS.highlights.set('matches', new Highlight(...ranges));
  CSS.highlights.set('current', new Highlight(...(hit >= 0 ? [ranges[hit]] : [])));
  if (reveal && hit >= 0) {
    revealElement(ranges[hit].startContainer.parentElement);
    revealElement(ranges[hit].endContainer.parentElement);
    const rect = ranges[hit].getBoundingClientRect();
    scrollTo(0, Math.max(0, scrollY + rect.top - innerHeight / 3));
  }
}
window.minutes = {
  async render(text, newContext, reset, ticket) {
    cancelNavigation();
    const current = ++generation;
    if (reset) lastUpdateEntries = null;
    const previous = lastUpdateEntries;
    clearUpdates();
    updateListeners.abort(); updateListeners = new AbortController();
    const saved = reset ? null : anchor(), selection = reset ? null : selectionOffsets();
    source = text; context = newContext;
    closeImage();
    root.innerHTML = safeHTML(md.render(withoutFrontmatter(text), { context, cleanHTML }));
    prepareSections(reset);
    decorateCallouts();
    rebuildTOC(reset);
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
      image.tabIndex = 0; image.setAttribute('role', 'button');
      image.setAttribute('aria-label', (image.alt || '画像') + 'を拡大');
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
        const definition = isTimeline(pre.textContent) ? wrapTimeline(pre.textContent, fitsTimelineNode) : pre.textContent;
        const { svg } = await mermaid.render('diagram-' + current + '-' + crypto.randomUUID(), definition);
        if (current !== generation) return;
        holder.innerHTML = DOMPurify.sanitize(svg, { USE_PROFILES: { svg: true, svgFilters: true }, FORBID_TAGS: ['foreignObject', 'script', 'a'] });
        pre.replaceWith(holder);
      } catch { pre.title = '図を描画できないため、記法を表示しています'; }
    }
    if (current !== generation) return;
    if (restore) { restoreAnchor(saved); restoreSelection(selection); }
    updateTOCPosition();
    refreshSearch();
    const entries = updateEntries(root);
    if (previous) highlightUpdates(changedEntries(previous, entries));
    // 中断された途中のDOMは比較元にしない。直前に描画を完了した本文だけを保持する。
    lastUpdateEntries = entries.map(({ key }) => ({ key }));
    report({ kind: 'rendered', ticket, text: root.innerText });
    return true;
  },
  clear() { cancelNavigation(); generation++; lastUpdateEntries = null; clearUpdates(); updateListeners.abort(); closeImage(); folded.clear(); source = ''; root.replaceChildren(); rebuildTOC(true); query = ''; refreshSearch(); scrollTo(0, 0); },
  invalidate() { cancelNavigation(); generation++; clearUpdates(); updateListeners.abort(); },
  search(value, direction = 0, reveal = true) {
    if (query !== value) { query = value; hit = 0; return refreshSearch(reveal); }
    if (ranges.length && direction) hit = (hit + direction + ranges.length) % ranges.length;
    paint(reveal); return { count: ranges.length, current: hit + 1 };
  },
  state() { return { text: root.innerText, width: root.getBoundingClientRect().width, scroll: scrollY, selection: selectionOffsets(), html: root.innerHTML }; },
  select(start, end) { restoreSelection([start, end]); },
};
root.addEventListener('pointerdown', () => report({ kind: 'focus' }));
root.addEventListener('keydown', event => {
  if (event.target.tagName === 'IMG' && (event.key === 'Enter' || event.key === ' ')) {
    event.preventDefault(); if (event.target.naturalWidth) openImage(event.target);
  }
});
root.addEventListener('click', event => {
  const image = event.target.closest('img');
  if (image && image.naturalWidth) { event.preventDefault(); openImage(image); return; }
  const link = event.target.closest('a'); if (!link) return;
  event.preventDefault();
  const href = link.getAttribute('href') || '';
  if (href.startsWith('#')) {
    let name; try { name = decodeURIComponent(href.slice(1)); } catch { return; }
    const target = document.getElementById(name) || document.getElementById('heading-' + name) ||
      [...root.querySelectorAll('[data-heading]')].find(el => el.dataset.heading === name);
    jumpTo(target); return;
  }
  report({ kind: 'link', href });
});
function decorateCallouts() {
  const faces = { tip:'tip',hint:'tip',success:'tip',check:'tip',done:'tip',important:'important',
    warning:'warning',attention:'warning',caution:'caution',danger:'caution',error:'caution',failure:'caution',bug:'caution' };
  const paths = {
    note:'M8 7v4 M8 4.5v.1 M14.4 8A6.4 6.4 0 1 1 1.6 8a6.4 6.4 0 0 1 12.8 0',
    tip:'M6 11C6 9 3.6 9 3.6 6a4.4 4.4 0 0 1 8.8 0c0 3-2.4 3-2.4 5Z M6.4 13.4h3.2',
    important:'M4 2h8v12l-4-3-4 3Z', warning:'M8 2 14.4 13.4H1.6Z M8 6v3 M8 11v.1',
    caution:'M5.6 1.7h4.8l3.9 3.9v4.8l-3.9 3.9H5.6l-3.9-3.9V5.6Z M8 5v3 M8 10.7v.1',
  };
  root.querySelectorAll('.callout').forEach(callout => {
    const face = faces[callout.dataset.kind] || 'note'; callout.dataset.face = face;
    const title = callout.querySelector(':scope > .callout-title'); if (!title) return;
    const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    icon.setAttribute('viewBox', '0 0 16 16'); icon.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS(icon.namespaceURI, 'path'); path.setAttribute('d', paths[face]);
    icon.append(path); title.prepend(icon);
  });
}
const imageDialog = document.createElement('dialog'); imageDialog.id = 'image-modal';
const modalImage = new Image(), modalClose = document.createElement('button');
modalClose.textContent = '×'; modalClose.type = 'button'; modalClose.setAttribute('aria-label', '拡大画像を閉じる');
imageDialog.setAttribute('aria-label', '画像の拡大表示');
imageDialog.append(modalClose, modalImage); document.body.append(imageDialog);
let imageOrigin;
function openImage(image) {
  imageOrigin = image; modalImage.src = image.currentSrc || image.src; modalImage.alt = image.alt;
  imageDialog.showModal(); modalClose.focus();
}
function closeImage() { if (imageDialog.open) imageDialog.close(); }
modalClose.addEventListener('click', closeImage);
imageDialog.addEventListener('click', event => { if (event.target === imageDialog) closeImage(); });
imageDialog.addEventListener('close', () => { modalImage.removeAttribute('src'); imageOrigin?.focus({ preventScroll:true }); imageOrigin = null; });
report({ kind: 'ready' });
