import { boardNodeID } from './board.js';

export function minimapTopicID(label, nodeID = '') {
  // 内蔵プロンプトはノードIDを論点IDとして保つ。ラベルと食い違っても優先し、
  // 数字始まりの本文が折り返しで連結しても論点IDへ混ぜない。
  if (/^T[1-9][0-9]*$/.test(nodeID)) return nodeID;
  // ノードIDが論点IDでない旧図ではラベルから読む。
  // Mermaidの折り返しではIDと本文の間の空白が消えることがある。
  // 英字・記号はIDの終端にできる。数字が連結した場合は長いIDの折り返しと
  // 区別できないため、途中で切らず先頭の連続数字をすべてIDとして読む。
  return /^\s*(?:[✅🟠❌💬]\uFE0F?\s*)?(T[1-9][0-9]*)(?![0-9])/u.exec(label)?.[1] || null;
}
export function minimapTextColor(fill, opacity = 1) {
  const rgb = /^rgba?\(([^)]+)\)$/.exec(fill)?.[1].split(/[\s,\/]+/).map(Number);
  if (!rgb || rgb.length < 3) return '#000';
  const alpha = (rgb[3] ?? 1) * Number(opacity);
  const luminanceOf = channels => channels.map(value => {
    const c = value / 255;
    return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  }).reduce((sum, value, i) => sum + value * [0.2126, 0.7152, 0.0722][i], 0);
  const luminance = luminanceOf(rgb.slice(0, 3).map(value => value * alpha + 255 * (1 - alpha)));
  const dark = luminance > 0.179;
  const gray = dark ? [61, 57, 53] : [238, 233, 226];
  const grayLuminance = luminanceOf(gray);
  const contrast = (Math.max(luminance, grayLuminance) + 0.05) / (Math.min(luminance, grayLuminance) + 0.05);
  // 墨・和紙に寄せた灰色でも4.5:1を保てる塗りだけ使う。
  if (contrast >= 4.5) return dark ? '#3d3935' : '#eee9e2';
  return luminance > 0.179 ? '#000' : '#fff';
}
export function minimapFontSize(heights) {
  const sorted = heights.filter(height => Number.isFinite(height) && height > 0).sort((a, b) => a - b);
  if (!sorted.length) return 0;
  const middle = Math.floor(sorted.length / 2);
  return (sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2) * 0.5625;
}
// 900px幅・30ノードで実測した7.518pxを保つ。pageZoom反映後の画面px。
export const MIN_MINIMAP_FONT_SIZE = 7.5;
export function minimapScale(bounds, viewport, fontSize) {
  const normal = Math.min(viewport.width * 0.33 / bounds.width, viewport.height * 0.27 / bounds.height);
  const maximum = Math.min(viewport.width * 0.5 / bounds.width, viewport.height * 0.4 / bounds.height);
  // IDなしの旧ボードは従来の大きさ。長いIDの幅による個別縮小は判定に含めない。
  return fontSize > 0 ? Math.min(maximum, Math.max(normal, MIN_MINIMAP_FONT_SIZE / fontSize)) : normal;
}
// 図の更新時だけ箱・ID・線を作る。ラベルと色は操作中に読み直さない。
export function createMinimap(svg, pageZoom = 1) {
  const NS = 'http://www.w3.org/2000/svg', drawing = document.createElementNS(NS, 'svg');
  drawing.setAttribute('viewBox', svg.getAttribute('viewBox'));
  drawing.setAttribute('pointer-events', 'none');
  const inverse = svg.getCTM().inverse();
  const transform = element => {
    const m = inverse.multiply(element.getCTM());
    // SVGのtransform属性はmatrix3dを受けない。DOMMatrixの6成分を明示する。
    return `matrix(${m.a} ${m.b} ${m.c} ${m.d} ${m.e} ${m.f})`;
  };
  for (const edge of svg.querySelectorAll('.edgePaths path')) {
    const path = document.createElementNS(NS, 'path');
    path.setAttribute('d', edge.getAttribute('d')); path.setAttribute('transform', transform(edge));
    path.setAttribute('fill', 'none'); path.setAttribute('stroke', '#6b6157');
    path.setAttribute('stroke-width', '2'); drawing.append(path);
  }
  // 箱の高さの中央値を基準にする。本文が複数行の箱だけIDを大きくしない。
  const nodes = [...svg.querySelectorAll('g.node')].map(node => ({ node, box:node.getBBox() }));
  const fontSize = minimapFontSize(nodes.map(({ box }) => box.height));
  for (const { node, box } of nodes) {
    const rect = document.createElementNS(NS, 'rect');
    const matrix = transform(node);
    for (const [name,value] of Object.entries({ x:box.x, y:box.y, width:box.width, height:box.height })) rect.setAttribute(name,value);
    rect.setAttribute('transform', matrix);
    // MermaidのclassDef・形状が持つ塗りと枠をそのまま写す。状態の色表は持たない。
    const shape = node.querySelector('.label-container') || node.querySelector('rect,polygon,circle,ellipse,path');
    if (shape) {
      const style = getComputedStyle(shape);
      for (const name of ['fill','fill-opacity','stroke','stroke-opacity','stroke-width'])
        rect.setAttribute(name, style.getPropertyValue(name));
      // WebKitのpageZoom下では点線の計算済みpx値だけが倍率で割られる。
      // その値をそのまま再指定すると二重に縮むため、SVGの図単位へ戻す。
      for (const name of ['stroke-dasharray','stroke-dashoffset'])
        rect.setAttribute(name, style.getPropertyValue(name).replace(/([-+]?\d*\.?\d+(?:e[-+]?\d+)?)px/gi,
          (_, value) => String(Number(value) * pageZoom)));
    }
    drawing.append(rect);
    const label = node.querySelector('.nodeLabel, .label');
    // textContentは折り返されたIDをつなぎ、入れ子のtspanも重複させずに読む。
    const id = minimapTopicID(label?.textContent || '', boardNodeID(node, svg));
    if (!id || box.width <= 0 || box.height <= 0) continue;
    // ノードごとのSVG viewportでクリップする。長いIDも隣の箱へはみ出さない。
    const group = document.createElementNS(NS, 'g'), viewport = document.createElementNS(NS, 'svg'), text = document.createElementNS(NS, 'text');
    // WebKitは入れ子のsvgのtransformを反映しないため、gへ座標変換を置く。
    group.setAttribute('transform', matrix);
    for (const [name, value] of Object.entries({ x:box.x, y:box.y, width:box.width, height:box.height,
      viewBox:`0 0 ${box.width} ${box.height}`, overflow:'hidden' })) viewport.setAttribute(name, value);
    for (const [name, value] of Object.entries({ x:box.width / 2, y:box.height / 2,
      'text-anchor':'middle', 'dominant-baseline':'central', 'font-family':'monospace', 'font-weight':'normal',
      'font-size':Math.min(fontSize, box.width * 0.85 / (id.length * 0.65)),
      fill:minimapTextColor(rect.getAttribute('fill') || '', rect.getAttribute('fill-opacity') || 1) })) text.setAttribute(name, value);
    text.textContent = id; viewport.append(text); group.append(viewport); drawing.append(group);
  }
  drawing.dataset.fontSize = drawing.querySelector('text') ? fontSize : 0;
  return drawing;
}
