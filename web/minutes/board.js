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

export function attachBoardLinks(holder, links, navigate) {
  const prefix = holder.querySelector('svg')?.id + '-';
  for (const node of holder.querySelectorAll('g.node')) {
    const localID = node.id.startsWith(prefix) ? node.id.slice(prefix.length) : node.id;
    const id = /^flowchart-(T[1-9][0-9]*)-[0-9]+$/.exec(localID)?.[1];
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
