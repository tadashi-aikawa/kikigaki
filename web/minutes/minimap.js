// 図の更新時だけ箱と線を作る。カードの描画済みの色を読み、操作中は読み直さない。
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
  for (const node of svg.querySelectorAll('g.node')) {
    const box = node.getBBox(), rect = document.createElementNS(NS, 'rect');
    for (const [name,value] of Object.entries({ x:box.x, y:box.y, width:box.width, height:box.height })) rect.setAttribute(name,value);
    rect.setAttribute('transform', transform(node));
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
  }
  return drawing;
}
