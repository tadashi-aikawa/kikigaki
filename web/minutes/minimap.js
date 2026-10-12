// Mermaidの文字・マーク・状態色を参照せず、図の更新時だけ粗い絵を作る。
export function createMinimap(svg) {
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
  for (const node of svg.querySelectorAll('g.node')) {
    const box = node.getBBox(), rect = document.createElementNS(NS, 'rect');
    for (const [name,value] of Object.entries({ x:box.x, y:box.y, width:box.width, height:box.height })) rect.setAttribute(name,value);
    rect.setAttribute('transform', transform(node));
    rect.setAttribute('fill', '#d8cdbd'); rect.setAttribute('stroke', '#6b6157'); drawing.append(rect);
  }
  return drawing;
}
