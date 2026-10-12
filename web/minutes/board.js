// MermaidのstrictとSVGのリンク禁止は維持する。単独行のT番号→文書内見出しだけを
// アプリ自身の移動操作へ変換し、Mermaidのcallbackや外部リンクは実行しない。
export function boardLinks(source) {
  const links = new Map();
  if (!/^\s*(?:flowchart|graph)\s+(?:TB|TD|BT|RL|LR)\b/.test(source)) return { definition: source, links };
  const definition = source.split('\n').map(line => {
    const match = /^\s*click\s+(T[1-9][0-9]*)\s+(?:href\s+)?"(#[^"<>\u0000-\u001f]+)"\s*;?\s*$/.exec(line);
    if (!match) return line;
    let target;
    try { target = decodeURIComponent(match[2].slice(1)); } catch { return ''; }
    if (target && !/[<>\u0000-\u001f]/.test(target)) links.set(match[1], target);
    return '';
  }).join('\n');
  return { definition, links };
}

export function boardNodeID(node, svg) {
  const prefix = svg.id + '-';
  const localID = node.id.startsWith(prefix) ? node.id.slice(prefix.length) : node.id;
  return /^flowchart-(T[1-9][0-9]*)-[0-9]+$/.exec(localID)?.[1] || null;
}
// 見出しの階層と名前を両方見る。同名クラスを持つ普通の図へ色を当てない。
export function isBoardHeading(text, level, heading = '## ボード') {
  const match = /^(#{1,6})[ \t]+(.+?)\s*$/.exec(heading.normalize('NFC'));
  if (!match || match[1].length !== level) return false;
  const label = text.normalize('NFC').trim(), name = match[2];
  if (label === name) return true;
  if (!label.startsWith(name)) return false;
  return /^\((?:[01][0-9]|2[0-3]):[0-5][0-9] 更新\)$/.test(label.slice(name.length));
}
export function styleRejectedBoardNodes(holder) {
  // MermaidのID付き!importantルールと古いclassDefよりも強いインライン!important。
  // ミニマップを作る前に描画済みSVGへ当て、元のMarkdownは変えない。
  for (const node of holder.querySelectorAll('g.node.rejected')) {
    for (const shape of node.querySelectorAll('.label-container, :scope > rect, :scope > polygon, :scope > circle, :scope > ellipse, :scope > path')) {
      for (const [key,value] of Object.entries({ fill:'#f9e6e3', stroke:'#c98b84',
        'stroke-width':'1px', 'stroke-dasharray':'2 2', 'stroke-dashoffset':'0', 'fill-opacity':'1', 'stroke-opacity':'1' }))
        shape.style.setProperty(key,value,'important');
    }
    for (const text of node.querySelectorAll('text,tspan')) {
      text.style.setProperty('fill','#9a9a9a','important');
      text.style.setProperty('color','#9a9a9a','important');
    }
  }
}
export function attachBoardLinks(holder, links, navigate) {
  const svg = holder.querySelector('svg');
  for (const node of holder.querySelectorAll('g.node')) {
    const id = boardNodeID(node, svg);
    if (!id || !links.has(id)) continue;
    node.setAttribute('role', 'link'); node.setAttribute('tabindex', '0');
    node.setAttribute('aria-label', '見出しへ: ' + links.get(id));
    node.style.cursor = 'pointer';
    node.addEventListener('click', event => { event.preventDefault(); navigate(links.get(id)); });
    node.addEventListener('keydown', event => {
      if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); navigate(links.get(id)); }
    });
  }
}
