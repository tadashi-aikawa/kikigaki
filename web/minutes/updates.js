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
export function updateEntries(root) {
  const groups = new Map(), walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    const node = walker.currentNode, parent = node.parentElement;
    if (!node.textContent.trim() || parent.closest('.heading-toggle,.katex-mathml,annotation,script,style')) continue;
    const block = parent.closest('h1,h2,h3,h4,h5,h6,p,li,td,th,pre,.callout-title,.diagram,div,summary') || parent;
    let entry = groups.get(block);
    if (!entry) { entry = { key:block.tagName + ':' + (block.getAttribute('style') || ''), nodes:[], element:block }; groups.set(block, entry); }
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
  return [...groups.values()];
}
let expiry, animations = [];
export function clearUpdates() {
  clearTimeout(expiry); CSS.highlights.delete('updated');
  animations.forEach(animation => animation.cancel()); animations = [];
}
export function highlightUpdates(entries) {
  clearUpdates();
  if (!entries.length) return;
  const ranges = [];
  for (const entry of entries.slice(0, 1000)) {
    if (entry.nodes.length) {
      const range = document.createRange(); range.setStart(entry.nodes[0], 0);
      range.setEnd(entry.nodes.at(-1), entry.nodes.at(-1).length); ranges.push(range);
    } else {
      animations.push(entry.element.animate([{ opacity:0.55 }, { opacity:1 }], { duration:4000 }));
    }
  }
  const highlight = new Highlight(...ranges); highlight.priority = -1;
  CSS.highlights.set('updated', highlight);
  expiry = setTimeout(clearUpdates, 4000);
}
