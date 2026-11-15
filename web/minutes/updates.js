// 描画された行の本文を比較する。行番号のずれや並べ替えで、無変更の後続行を光らせない。
export function changedEntries(previous, current) {
  const counts = new Map();
  for (const entry of previous) counts.set(entry.key, (counts.get(entry.key) || 0) + 1);
  return current.filter(entry => {
    const count = counts.get(entry.key) || 0;
    if (count) { counts.set(entry.key, count - 1); return false; }
    return true;
  });
}
// 強調の比較元。基準がある間はAIの1依頼分の編集を累積し、無ければ直前の描画と比べる。
export class UpdateHighlighter {
  #previous = null;
  #baseline = null;
  get hasBaseline() { return this.#baseline !== null; }
  // 会議・表示対象の切替。累積をやめ、次の描画を初回として扱う。
  reset() { this.#previous = null; this.#baseline = null; }
  // AIへの依頼の送信と編集の開始。今の本文を基準に置き直し、それまでの強調を捨てる。
  mark() { this.#baseline = { entries: this.#previous }; }
  // 描画のたびに呼ぶ。強調する項目と、4秒で消さずに残すかを返す。
  plan(entries) {
    const keys = entries.map(({ key, figure, note }) => ({ key, figure, note }));
    let changed = [], before = null;
    if (this.#baseline) {
      // 基準を置いた時点で本文が無ければ、最初の描画を基準にして初回表示を光らせない。
      if (this.#baseline.entries) before = this.#baseline.entries;
      else this.#baseline = { entries: keys };
    } else before = this.#previous;
    if (before) {
      // 図の枠を光らせるのは、比べる側にも今の側にも付箋の無い図だけ。最後の付箋を消した図は光らせない。
      const noted = new Set(before.filter(entry => entry.note !== undefined).map(entry => entry.figure));
      changed = changedEntries(before, entries)
        .filter(entry => entry.figure === undefined || entry.note !== undefined || !noted.has(entry.figure));
    }
    this.#previous = keys;
    return { entries: changed, persist: this.hasBaseline };
  }
}
// SVGの図の比べる項目。付箋のある図は付箋ごとに、図の名前・付箋の名前・文で比べる。
// 位置・色・大きさだけが変わった付箋は同じ項目になり、光らない。付箋の無い図は、原文で図の枠を比べる。
// figure は図を突き合わせる名前、element は本文の中の置き場、highlight は付箋を光らせる関数。
export function figureEntries(figures) {
  const entries = [];
  for (const { figure, element, hash, notes, highlight } of figures) {
    if (!notes.length) { entries.push({ key:'FIG:' + hash, nodes:[], element, figure }); continue; }
    for (const note of notes) entries.push({
      key:'NOTE:' + JSON.stringify([figure, note.id, note.text]), nodes:[], element, figure, note:note.id, highlight,
    });
  }
  return entries;
}
export function updateEntries(root) {
  const groups = new Map(), walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode, parent = node.parentElement;
    if (!node.textContent.trim() || parent.closest('.heading-toggle,.code-copy,.diagram-controls,.katex-mathml,annotation,script,style')) continue;
    const block = parent.closest('h1,h2,h3,h4,h5,h6,p,li,td,th,pre,.callout-title,.diagram,div,summary') || parent;
    let entry = groups.get(block);
    // 図を動かしただけでは、本文の更新として強調しない。
    const style = block.classList.contains('diagram-stage') ? '' : block.getAttribute('style') || '';
    if (!entry) { entry = { key:block.tagName + ':' + style, nodes:[], element:block }; groups.set(block, entry); }
    entry.nodes.push(node); entry.key += node.textContent;
    for (let element = parent; element && element !== block; element = element.parentElement) {
      entry.key += '[' + element.tagName + ':' + (element.getAttribute('style') || '') + ']';
    }
  }
  for (const [block, entry] of groups) {
    const checkbox = block.querySelector(':scope > input[type="checkbox"]');
    if (checkbox) entry.key += checkbox.checked ? ':checked' : ':unchecked';
  }
  for (const image of root.querySelectorAll('img')) {
    let url; try { url = new URL(image.src); } catch { continue; }
    const key = url.protocol === 'minutes-image:' ? url.searchParams.get('path') : image.src;
    groups.set(image, { key:'IMG:' + key, nodes:[], element:image });
  }
  // SVGの図は親のDOMに文字を持たない。比べる項目は figureEntries が作る。
  return [...groups.values()];
}
// 変更のあった要素を含む見出しを、内側から順に並べて返す。
// 見出し自身が変わった場合はその見出しが先頭に来る (見出しも .heading-section の中にある)。
export function updatedHeadings(entries) {
  return entries.map(entry => {
    const chain = [];
    for (let section = entry.element.closest('.heading-section'); section;
         section = section.parentElement?.closest('.heading-section')) {
      const heading = section.querySelector(':scope > :is(h1,h2,h3,h4,h5,h6)');
      if (heading) chain.push(heading);
    }
    return chain;
  });
}
// 内側から順の見出しの連なりを畳み、見出しごとの印を決める。
// 直接その見出しの中身が変わったものは 'self'、配下の見出しだけが変わったものは 'descendant'。
// 同じ見出しに両方当たれば 'self' を優先する。要素でも添字でも同じように使える。
export function foldUpdateMarks(chains) {
  const marks = new Map();
  for (const chain of chains) {
    for (let depth = 0; depth < chain.length; depth++) {
      const key = chain[depth];
      if (key == null) continue;
      if (depth === 0) marks.set(key, 'self');
      else if (!marks.has(key)) marks.set(key, 'descendant');
    }
  }
  return marks;
}
let expiry, animations = [], marked = [], markedLinks = [], figureCleanups = [];
export function clearUpdates() {
  clearTimeout(expiry); CSS.highlights.delete('updated');
  // 図の中の強調は、iframeへも消すよう伝える。
  figureCleanups.forEach(cleanup => cleanup()); figureCleanups = [];
  animations.forEach(animation => animation.cancel()); animations = [];
  marked.forEach(element => element.classList.remove('updated-block')); marked = [];
  markedLinks.forEach(link => delete link.dataset.updated); markedLinks = [];
}
// tocLinkFor は見出しから目次のリンクを引く。目次に無い見出しでは undefined を返してよい。
export function highlightUpdates(entries, persist = false, tocLinkFor = null) {
  clearUpdates();
  if (!entries.length) return;
  if (tocLinkFor) {
    for (const [heading, mark] of foldUpdateMarks(updatedHeadings(entries))) {
      // 目次は先頭300見出しまで。そこから外れた見出しには印を持てない。
      const link = tocLinkFor(heading);
      if (!link) continue;
      link.dataset.updated = mark; markedLinks.push(link);
    }
  }
  const ranges = [], notes = new Map();
  for (const entry of entries.slice(0, 1000)) {
    if (entry.note !== undefined) {
      // 付箋は図ごとにまとめ、iframeの中で付箋の外形に重ねて描く。
      if (!entry.highlight) continue;
      if (!notes.has(entry.highlight)) notes.set(entry.highlight, []);
      notes.get(entry.highlight).push(entry.note);
    } else if (entry.nodes.length) {
      const range = document.createRange(); range.setStart(entry.nodes[0], 0);
      range.setEnd(entry.nodes.at(-1), entry.nodes.at(-1).length); ranges.push(range);
    } else if (persist) {
      // 消えないアニメーションは持てない。文字を持たない画像だけ枠で示す。
      entry.element.classList.add('updated-block'); marked.push(entry.element);
    } else {
      animations.push(entry.element.animate([{ opacity:0.55 }, { opacity:1 }], { duration:4000 }));
    }
  }
  for (const [highlight, ids] of notes) figureCleanups.push(highlight(ids));
  const highlight = new Highlight(...ranges); highlight.priority = -1;
  CSS.highlights.set('updated', highlight);
  // 基準がある間は1依頼分の編集をすべて残す。時間では消さない。
  if (!persist) expiry = setTimeout(clearUpdates, 4000);
}
