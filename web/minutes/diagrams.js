import { boardNodeID } from './board.js';
import { createMinimap, minimapScale } from './minimap.js';
// pageZoomとは独立した、図ごとの表示倍率。座標はページのCSS pxで保持する。
export const MIN_DIAGRAM_SCALE = 0.25, MAX_DIAGRAM_SCALE = 4;
export function zoomDiagram(state, scale, point) {
  const next = Math.max(MIN_DIAGRAM_SCALE, Math.min(MAX_DIAGRAM_SCALE, scale));
  if (!Number.isFinite(next)) return;
  const ratio = next / state.scale;
  state.x = point.x - (point.x - state.x) * ratio;
  state.y = point.y - (point.y - state.y) * ratio;
  state.scale = next;
}

// boundsは窓内のCSS px。丸め誤差で、ちょうど収まる辺へ印を出さない。
export function diagramOverflow(bounds, viewport) {
  return {
    left:bounds.x < -1, right:bounds.x + bounds.width > viewport.width + 1,
    top:bounds.y < -1, bottom:bounds.y + bounds.height > viewport.height + 1,
  };
}
export function fitDiagram(state, bounds, viewport, maximum = MAX_DIAGRAM_SCALE) {
  if (bounds.width <= 0 || bounds.height <= 0 || viewport.width <= 0 || viewport.height <= 0) return;
  state.scale = Math.max(MIN_DIAGRAM_SCALE, Math.min(maximum,
    viewport.width / bounds.width, viewport.height / bounds.height));
  state.x = (viewport.width - bounds.width * state.scale) / 2 - bounds.x * state.scale;
  state.y = (viewport.height - bounds.height * state.scale) / 2 - bounds.y * state.scale;
}

export class DiagramInteractions {
  constructor() {
    this.states = new Map();
    this.selected = null;
    document.addEventListener('click', event => {
      if (!event.target.closest('.diagram')) this.deselect();
    });
    document.addEventListener('keydown', event => {
      if (event.key === 'Escape' && [...this.states.values()].some(state => state.selected)) {
        event.preventDefault();
        if (this.selected?.state.canvas) this.selected.clearFocus(); else this.deselect();
      }
    });
    addEventListener('scroll', () => this.positionControls(), { passive:true });
    addEventListener('resize', () => this.positionControls());
    document.getElementById('toc')?.addEventListener('toggle', () => this.positionControls());
  }
  positionControls() {
    if (!this.selected) return;
    const { holder, controls } = this.selected;
    const gap = 6, frame = holder.getBoundingClientRect();
    // fixedの座標をviewportのCSS pxに揃える。短い図で目次の下へ逃がす場合も、
    // 図のoverflow:hiddenで操作列を切らず、図や枠の寸法は変えない。
    controls.style.maxWidth = Math.max(0, holder.clientWidth - gap * 2) + 'px';
    controls.style.left = frame.left + gap + 'px';
    controls.style.top = frame.top + gap + 'px';
    const width = controls.getBoundingClientRect().width;
    controls.style.left = frame.right - width - gap + 'px';
    const toc = document.getElementById('toc');
    if (!toc || toc.hidden) return;
    const menu = toc.getBoundingClientRect(), box = controls.getBoundingClientRect();
    if (box.top < menu.bottom && box.bottom > menu.top && box.right > menu.left && box.left < menu.right) {
      const left = menu.left - width - gap;
      // 目次の左へ収まらなければ、その下へ逃がす。幅不足を左端で打ち切らない。
      if (left >= frame.left + gap) controls.style.left = left + 'px';
      else controls.style.top = menu.bottom + gap + 'px';
    }
  }
  reset() { this.selected?.cancel(); this.selected = null; this.states.clear(); }
  revealSearch(node) {
    if (this.selected?.state.canvas && this.selected.holder.contains(node)) {
      // 同じノード内の次の一致も、見出し移動の2回目のクリックにはしない。
      this.selected.focusNode(node, { navigateAgain:false, minimumScale:1, center:true });
    }
  }
  paintSearch(matches, current) { this.selected?.paintSearch?.(matches, current); }
  // 再描画中に古いDOMを操作しない。選択キーと状態は次のDOMへ引き継ぐ。
  detach() { this.selected?.remember?.(); this.selected?.cancel(); this.selected = null; }
  deselect() {
    if (this.selected?.state.canvas) return;
    if (this.selected) {
      this.selected.holder.classList.remove('diagram-selected', 'diagram-dragging');
      // Escではクリックによるフォーカス移動が起きない。倍率ボタンやカードも含めて抜ける。
      if (this.selected.holder.contains(document.activeElement)) document.activeElement.blur();
      this.selected.state.selected = false;
      this.selected.cancel();
    }
    // 非同期再描画で選択中のDOMがまだ無い間の解除も、次の図へ持ち越さない。
    for (const state of this.states.values()) state.selected = false;
    this.selected = null;
  }
  attach(holder, key, { canvas = false, navigate = () => {}, pageZoom = 1 } = {}) {
    const state = this.states.get(key) || { scale:1, x:0, y:0, window:canvas, selected:canvas, mode:'fit', focusID:null };
    state.canvas = canvas;
    this.states.set(key, state);
    holder.dataset.diagramKey = key;
    holder.tabIndex = 0;
    holder.setAttribute('aria-label', canvas ? 'ボード。拡大縮小・移動。ノードをクリックでフォーカス、Escで解除' : 'Mermaid図。クリックで選択し、拡大縮小・移動。Escで解除');
    holder.classList.toggle('board-canvas', canvas);
    const stage = document.createElement('div'); stage.className = 'diagram-stage';
    stage.append(...holder.childNodes); holder.append(stage);
    // 新しいSVGの自然寸法を、transformを掛ける前に測る。高さはDOMごとの値で、
    // 再描画へ持ち越さない。選択時はこの高さを使い、周囲の配置を変えない。
    // 折り畳まれた節ではDOMの高さが0になる。自然幅はviewBox幅と同じなので、
    // その場合はSVGの自然高を使い、節を開いたあとも図を潰さない。
    let height = holder.getBoundingClientRect().height || stage.querySelector('svg').viewBox.baseVal.height;
    const svg = stage.querySelector('svg');
    const nodes = new Map(), nodeBoxes = new Map();
    if (canvas) for (const node of svg.querySelectorAll('g.node')) {
      const id = boardNodeID(node, svg);
      if (!id) continue;
      nodes.set(id, node); node.dataset.nodeId = id;
      nodeBoxes.set(node, node.getBBox());
      node.setAttribute('role', 'button'); node.setAttribute('tabindex', '0');
      node.setAttribute('aria-label', node.textContent + '。クリックでフォーカス、もう一度で見出しへ');
    }
    const edges = document.createElement('div'); edges.className = 'diagram-edges';
    edges.setAttribute('aria-hidden', 'true');
    for (const side of ['left', 'right', 'top', 'bottom']) {
      const edge = document.createElement('span'); edge.className = 'diagram-edge';
      edge.dataset.side = side; edges.append(edge);
    }
    if (!canvas) holder.append(edges);
    let canvasFrame, canvasBounds;
    const canvasNodeBounds = new Map();
    let painted = { scale:1, x:0, y:0 };
    const measureCanvas = () => {
      canvasFrame = holder.getBoundingClientRect();
      const box = svg.getBoundingClientRect();
      canvasBounds = { x:(box.left-canvasFrame.left-painted.x)/painted.scale,
        y:(box.top-canvasFrame.top-painted.y)/painted.scale, width:box.width/painted.scale, height:box.height/painted.scale };
      // フォーカスとミニマップの重なりも、初回・リサイズ時の矩形から求める。
      // ドラッグ中にノードのレイアウトを読み直さない。
      for (const [id, node] of nodes) {
        const rect = node.getBoundingClientRect();
        canvasNodeBounds.set(id, { x:(rect.left-canvasFrame.left-painted.x)/painted.scale,
          y:(rect.top-canvasFrame.top-painted.y)/painted.scale, width:rect.width/painted.scale, height:rect.height/painted.scale });
      }
    };
    if (canvas) measureCanvas();
    const viewport = () => {
      // WebKitのpageZoom下ではclientHeightの整数丸めが数pxずれる。
      // はみ出しの無い図の下端へ誤って印を出さないよう、実際の枠を使う。
      const frame = canvas ? canvasFrame : holder.getBoundingClientRect();
      const scrollbar = !state.window && holder.scrollWidth > holder.clientWidth + 1
        ? Math.max(0, holder.offsetHeight - holder.clientHeight) : 0;
      return { width:frame.width, height:frame.height - scrollbar };
    };
    const bounds = () => {
      if (canvas) return { x:canvasBounds.x*state.scale+state.x, y:canvasBounds.y*state.scale+state.y,
        width:canvasBounds.width*state.scale, height:canvasBounds.height*state.scale };
      const frame = holder.getBoundingClientRect(), box = svg.getBoundingClientRect();
      return { x:box.left - frame.left, y:box.top - frame.top, width:box.width, height:box.height };
    };
    const updateEdges = () => {
      if (canvas) { updateMinimap(); return; }
      const size = viewport(), visible = diagramOverflow(bounds(), size);
      // 絶対配置の層をスクロール量だけ戻し、未選択でも窓の端へ固定する。
      edges.style.left = holder.scrollLeft + 'px'; edges.style.top = holder.scrollTop + 'px';
      edges.style.width = size.width + 'px'; edges.style.height = size.height + 'px';
      for (const edge of edges.children) edge.hidden = !visible[edge.dataset.side];
    };
    const naturalBounds = () => {
      if (canvas) return canvasBounds;
      const box = bounds();
      return { x:(box.x - state.x) / state.scale, y:(box.y - state.y) / state.scale,
        width:box.width / state.scale, height:box.height / state.scale };
    };
    const fitAll = () => {
      fitDiagram(state, naturalBounds(), viewport(), canvas ? 2 : MAX_DIAGRAM_SCALE);
      state.mode = 'fit';
    };
    const nodePoint = node => {
      const box = node.getBoundingClientRect(), frame = holder.getBoundingClientRect();
      return { x:(box.left + box.right) / 2 - frame.left, y:(box.top + box.bottom) / 2 - frame.top };
    };
    const remember = () => {
      if (!canvas || state.mode === 'fit') return;
      // 次の描画へ渡す画面位置は、まだrAF待ちの最後の入力も反映してから読む。
      if (applyFrame !== null) apply({ delayedMap:true });
      const center = { x:holder.clientWidth / 2, y:holder.clientHeight / 2 };
      let id = state.focusID;
      if (!id) id = [...nodes.keys()].sort((a, b) => {
        const p = nodePoint(nodes.get(a)), q = nodePoint(nodes.get(b));
        return Math.hypot(p.x-center.x,p.y-center.y) - Math.hypot(q.x-center.x,q.y-center.y);
      })[0];
      state.anchor = nodes.has(id) ? { id, ...nodePoint(nodes.get(id)) } : null;
    };
    let focusMark = null, focusScale = null;
    const clearFocus = () => {
      state.focusID = null;
      focusMark = null;
      for (const node of nodes.values()) {
        node.querySelector('.board-focus-ring')?.remove(); node.setAttribute('aria-pressed','false');
      }
      if (holder.contains(document.activeElement)) document.activeElement.blur();
      if (canvas) delayMinimap();
    };
    const resizeFocus = () => {
      if (!focusMark || focusScale === state.scale) return;
      const box = nodeBoxes.get(nodes.get(state.focusID));
      const arm = Math.max(14, 10 / state.scale), x0 = box.x-6, y0 = box.y-6,
        x1 = box.x+box.width+6, y1 = box.y+box.height+6;
      focusMark.setAttribute('d', `M${x0},${y0+arm}V${y0}H${x0+arm} M${x1-arm},${y0}H${x1}V${y0+arm} M${x1},${y1-arm}V${y1}H${x1-arm} M${x0+arm},${y1}H${x0}V${y1-arm}`);
      focusScale = state.scale;
    };
    const paintFocus = () => {
      focusMark = null; focusScale = null;
      for (const [id, node] of nodes) {
        node.querySelector('.board-focus-ring')?.remove();
        node.setAttribute('aria-pressed', String(id === state.focusID));
        if (id !== state.focusID) continue;
        const ring = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        ring.setAttribute('class', 'board-focus-ring');
        // MermaidがSVG内に置く「#図ID .node rect」の塗りより優先する。
        // 枠だけを重ね、文字を覆うノードの地にはしない。
        ring.style.cssText = 'fill:none!important;stroke:#2b2420!important;stroke-width:3px!important;stroke-linecap:square;vector-effect:non-scaling-stroke;pointer-events:none';
        node.append(ring); focusMark = ring;
      }
      resizeFocus();
      if (canvas) updateMinimap();
    };
    const paintSearch = (matches, current) => {
      for (const node of nodes.values()) node.querySelector('.board-search-ring')?.remove();
      for (const node of new Set(matches)) {
        if (!nodeBoxes.has(node)) continue;
        const box = nodeBoxes.get(node), ring = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
        ring.setAttribute('class', 'board-search-ring');
        ring.dataset.current = String(node === current);
        // SVGの文字はCSS Highlightの背景が描かれないため、ノードの内側の枠でも一致を示す。
        ring.style.cssText = `fill:none!important;stroke:${node === current ? '#8a5a12' : '#e09c3c'}!important;stroke-width:${node === current ? 3 : 2}px!important;vector-effect:non-scaling-stroke;pointer-events:none`;
        for (const [name,value] of Object.entries({ x:box.x-2, y:box.y-2, width:box.width+4, height:box.height+4, rx:3 })) ring.setAttribute(name,value);
        node.append(ring);
      }
    };
    const focusNode = (node, { navigateAgain = true, minimumScale = 0, center = false } = {}) => {
      const id = node.dataset.nodeId;
      if (navigateAgain && state.focusID === id) { navigate(id); return; }
      clearFocus(); state.focusID = id; state.mode = 'manual';
      if (center) {
        if (applyFrame !== null) apply({ delayedMap:true });
        const point = nodePoint(node);
        zoomDiagram(state, Math.max(state.scale, minimumScale), point);
        state.x += holder.clientWidth / 2 - point.x; state.y += holder.clientHeight / 2 - point.y;
        apply();
      }
      paintFocus();
    };
    // 本体のSVGをuseで再描画せず、状態色を写した箱・論点ID・線を1回作る。
    const minimap = document.createElement('div'); minimap.className = 'board-minimap'; minimap.hidden = true;
    minimap.setAttribute('role', 'group'); minimap.setAttribute('aria-label', 'ボード全体と表示範囲');
    const mapSVG = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const drawing = canvas ? createMinimap(svg, pageZoom) : document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    const mapFrame = document.createElementNS('http://www.w3.org/2000/svg', 'rect'); mapFrame.setAttribute('class', 'board-map-frame');
    mapSVG.append(drawing, mapFrame); minimap.append(mapSVG);
    if (canvas) holder.append(minimap);
    const updateMinimap = () => {
      const size = viewport(), box = bounds(), natural = naturalBounds();
      minimap.hidden = !Object.values(diagramOverflow(box, size)).some(Boolean);
      if (minimap.hidden || natural.width <= 0 || natural.height <= 0) return;
      // SVG図単位の共通文字サイズを自然寸法のCSS pxへ戻す。
      // 初回に保持した値だけを使い、操作中にラベル・色・箱を読み直さない。
      const fontSize = Number(drawing.dataset.fontSize) * natural.height / drawing.viewBox.baseVal.height * pageZoom;
      const ratio = minimapScale(natural, size, fontSize);
      mapSVG.setAttribute('viewBox', `0 0 ${natural.width} ${natural.height}`);
      mapSVG.style.width = natural.width * ratio + 'px'; mapSVG.style.height = natural.height * ratio + 'px';
      drawing.setAttribute('width', natural.width); drawing.setAttribute('height', natural.height);
      const focus = canvasNodeBounds.get(state.focusID);
      const width = natural.width * ratio + 8, height = natural.height * ratio + 8;
      const overlap = (x, y) => {
        if (!focus) return 0;
        const left = focus.x*state.scale+state.x-8, top = focus.y*state.scale+state.y-8;
        return Math.max(0, Math.min(x+width, left+focus.width*state.scale+16)-Math.max(x,left)) *
          Math.max(0, Math.min(y+height, top+focus.height*state.scale+16)-Math.max(y,top));
      };
      // 通常は右下。フォーカスを覆う間だけ他の隅へ逃がす。
      // 上側は操作列、下左は「以前の本文」のボタン分を空ける。
      const corners = [{ x:size.width-width-12, y:size.height-height-12 },
        { x:12, y:size.height-height-(holder.querySelector('.board-legacy') ? 48 : 12) },
        { x:12, y:48 }, { x:size.width-width-12, y:48 }];
      const corner = corners.reduce((best, next) => overlap(next.x,next.y) < overlap(best.x,best.y) ? next : best);
      minimap.style.left = Math.max(0, corner.x) + 'px'; minimap.style.top = Math.max(0, corner.y) + 'px';
      minimap.style.right = minimap.style.bottom = 'auto';
      const left = Math.max(0, -box.x / state.scale), top = Math.max(0, -box.y / state.scale);
      const right = Math.min(natural.width, (size.width-box.x) / state.scale);
      const bottom = Math.min(natural.height, (size.height-box.y) / state.scale);
      for (const [name,value] of Object.entries({ x:left, y:top, width:Math.max(0,right-left), height:Math.max(0,bottom-top) })) mapFrame.setAttribute(name,value);
    };
    let mapTimer = null;
    const delayMinimap = () => {
      if (mapTimer !== null) return;
      mapTimer = setTimeout(() => { mapTimer = null; if (holder.isConnected) updateMinimap(); }, 100);
    };
    const controls = document.createElement('div'); controls.className = 'diagram-controls';
    controls.setAttribute('role', 'group'); controls.setAttribute('aria-label', '図の倍率');
    const label = document.createElement('output');
    const button = (text, name, action) => {
      const element = document.createElement('button'); element.type = 'button';
      // 操作ラベルを本文・検索・更新比較・選択の文字位置へ混ぜない。
      element.dataset.label = text; element.setAttribute('aria-label', name); element.title = name;
      element.addEventListener('click', event => { event.stopPropagation(); action(); });
      return element;
    };
    const center = () => ({ x:holder.clientWidth / 2, y:holder.clientHeight / 2 });
    const minus = button('−', '図を縮小', () => zoom(state.scale / 1.25, center()));
    const plus = button('+', '図を拡大', () => zoom(state.scale * 1.25, center()));
    const fit = button('全体', '図の全体を枠に収める', () => {
      clearFocus(); fitAll();
      apply();
    });
    const reset = button('戻す', '図を等倍・初期位置へ戻す', () => {
      clearFocus(); state.mode = 'manual'; state.scale = 1; state.x = state.y = 0; apply();
    });
    controls.append(minus, label, plus, fit, reset); holder.append(controls);
    let drag = null, gesture = null, suppressClick = false, applyFrame = null;
    const apply = ({ delayedMap = false } = {}) => {
      if (applyFrame !== null) { cancelAnimationFrame(applyFrame); applyFrame = null; }
      if (state.window && !canvas) {
        holder.classList.add('diagram-window'); holder.style.height = height + 'px';
      }
      stage.style.transform = `translate(${state.x}px, ${state.y}px) scale(${state.scale})`;
      painted = { scale:state.scale, x:state.x, y:state.y };
      if (canvas) resizeFocus();
      const text = Math.round(state.scale * 100) + '%', changedLabel = label.dataset.label !== text;
      if (changedLabel) {
        label.dataset.label = text;
        label.setAttribute('aria-label', '図の倍率 ' + text);
      }
      minus.disabled = state.scale <= MIN_DIAGRAM_SCALE;
      plus.disabled = state.scale >= MAX_DIAGRAM_SCALE;
      if (canvas && delayedMap) delayMinimap(); else updateEdges();
      if (!canvas || changedLabel) this.positionControls();
    };
    const queueApply = () => {
      if (!canvas) { apply(); return; }
      if (applyFrame !== null) return;
      applyFrame = requestAnimationFrame(() => { applyFrame = null; apply({ delayedMap:true }); });
    };
    const zoom = (scale, point, delayedMap = false) => {
      state.mode = 'manual'; zoomDiagram(state, scale, point);
      if (canvas && delayedMap) queueApply(); else apply();
    };
    const point = event => {
      const rect = canvas ? canvasFrame : holder.getBoundingClientRect();
      return { x:event.clientX - rect.left, y:event.clientY - rect.top };
    };
    let mapDrag = null;
    const cancel = () => {
      if (drag && holder.hasPointerCapture(drag.id)) holder.releasePointerCapture(drag.id);
      if (mapDrag !== null && minimap.hasPointerCapture(mapDrag)) minimap.releasePointerCapture(mapDrag);
      mapDrag = drag = gesture = null; holder.classList.remove('diagram-dragging');
    };
    const select = () => {
      if (this.selected?.holder === holder) return;
      this.deselect();
      if (!state.window) {
        // borderを足さずoutlineで囲む。スクロールバーを含む高さと表示位置を保つ。
        height = holder.getBoundingClientRect().height;
        state.window = true;
        state.x = -holder.scrollLeft; state.y = -holder.scrollTop;
        holder.scrollLeft = holder.scrollTop = 0;
      }
      state.selected = true; this.selected = { holder, state, cancel, controls, clearFocus, remember, focusNode, paintSearch };
      holder.classList.add(canvas ? 'canvas-active' : 'diagram-selected'); apply();
      if (!canvas) holder.focus({ preventScroll:true });
    };
    holder.addEventListener('click', event => {
      if (suppressClick) { event.preventDefault(); event.stopImmediatePropagation(); suppressClick = false; return; }
      if (canvas && !event.target.closest('.diagram-controls,.board-minimap')) {
        const node = event.target.closest('[data-node-id]');
        event.preventDefault(); event.stopImmediatePropagation();
        if (node) focusNode(node); else clearFocus();
        return;
      }
      if (!state.selected) {
        // 最初のクリックは選択。選択後のカードのクリックは既存の見出し移動を使う。
        event.preventDefault(); event.stopImmediatePropagation(); select();
      }
    }, true);
    holder.addEventListener('pointerdown', event => {
      if (!state.selected || event.button !== 0 || event.target.closest('.diagram-controls,.board-minimap')) return;
      event.preventDefault(); suppressClick = false;
      drag = { id:event.pointerId, x:event.clientX, y:event.clientY, moved:false };
      // 移動し始めてからcaptureする。単なるカードクリックの宛先は変えない。
    });
    const move = event => {
      if (!drag || drag.id !== event.pointerId) return;
      const dx = event.clientX - drag.x, dy = event.clientY - drag.y;
      if (!drag.moved && Math.hypot(dx, dy) < 3) return;
      drag.moved = true;
      if (event.isTrusted && !holder.hasPointerCapture(drag.id)) holder.setPointerCapture(drag.id);
      holder.classList.add('diagram-dragging');
      state.mode = 'manual'; state.x += dx; state.y += dy; drag.x = event.clientX; drag.y = event.clientY; queueApply();
    };
    const end = event => {
      if (!drag || drag.id !== event.pointerId) return;
      suppressClick = drag.moved; cancel();
    };
    // capture前に図の外へ出た場合も、同じドラッグを終えられる。
    const listeners = new AbortController();
    holder.addEventListener('scroll', updateEdges, { passive:true, signal:listeners.signal });
    const observer = new ResizeObserver(() => {
      if (canvas) measureCanvas();
      if (canvas && state.mode === 'fit') { fitAll(); apply(); }
      else { updateEdges(); this.positionControls(); }
    });
    observer.observe(holder); observer.observe(svg);
    document.addEventListener('pointermove', move, { signal:listeners.signal });
    document.addEventListener('pointerup', end, { signal:listeners.signal });
    holder.addEventListener('pointercancel', cancel);
    holder.addEventListener('lostpointercapture', cancel);
    holder.addEventListener('wheel', event => {
      if (!state.selected || event.target.closest('.diagram-controls,.board-minimap')) return;
      // ⌘の文字倍率はネイティブのメニューへ任せる。
      if (event.metaKey) return;
      event.preventDefault();
      if (event.ctrlKey) {
        // Safariのgesture経路と同時に来ても倍率を二重に掛けない。
        if (!gesture) zoom(state.scale * Math.exp(-event.deltaY * 0.01), point(event), true);
      } else {
        const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? holder.clientHeight : 1;
        state.mode = 'manual'; state.x -= event.deltaX * unit; state.y -= event.deltaY * unit; queueApply();
      }
    }, { passive:false });
    holder.addEventListener('gesturestart', event => {
      if (!state.selected || event.target.closest('.diagram-controls,.board-minimap')) return;
      event.preventDefault(); gesture = { scale:state.scale, point:point(event) };
    }, { passive:false });
    holder.addEventListener('gesturechange', event => {
      if (!state.selected || !gesture) return;
      event.preventDefault(); zoom(gesture.scale * event.scale, gesture.point, true);
    }, { passive:false });
    holder.addEventListener('gestureend', event => {
      if (!gesture) return;
      event.preventDefault(); gesture = null;
    }, { passive:false });
    const moveMap = event => {
      const transform = mapSVG.getScreenCTM();
      if (!transform) return;
      const point = new DOMPoint(event.clientX,event.clientY).matrixTransform(transform.inverse()), natural = naturalBounds();
      state.mode = 'manual';
      state.x = holder.clientWidth/2 - (natural.x + Math.max(0,Math.min(natural.width,point.x))) * state.scale;
      state.y = holder.clientHeight/2 - (natural.y + Math.max(0,Math.min(natural.height,point.y))) * state.scale;
      apply();
    };
    minimap.addEventListener('click', event => { event.preventDefault(); event.stopPropagation(); moveMap(event); });
    minimap.addEventListener('pointerdown', event => {
      if (event.button !== 0) return;
      event.preventDefault(); event.stopPropagation(); mapDrag = event.pointerId;
      if (event.isTrusted) minimap.setPointerCapture(event.pointerId);
      moveMap(event);
    });
    document.addEventListener('pointermove', event => { if (event.pointerId === mapDrag) moveMap(event); }, { signal:listeners.signal });
    const endMap = event => { if (event.pointerId === mapDrag) mapDrag = null; };
    document.addEventListener('pointerup', endMap, { signal:listeners.signal });
    minimap.addEventListener('pointercancel', endMap); minimap.addEventListener('lostpointercapture', endMap);
    holder.addEventListener('keydown', event => {
      const node = event.target.closest('[data-node-id]');
      if (canvas && node && (event.key === 'Enter' || event.key === ' ')) {
        event.preventDefault(); focusNode(node);
      }
    });
    apply();
    if (canvas) {
      if (state.mode === 'fit') fitAll();
      else if (nodes.has(state.anchor?.id)) {
        const point = nodePoint(nodes.get(state.anchor.id));
        state.x += state.anchor.x-point.x; state.y += state.anchor.y-point.y;
      }
      if (!nodes.has(state.focusID)) state.focusID = null;
      state.anchor = null; apply(); paintFocus();
    }
    if (state.selected) select();
    return () => { cancel(); cancelAnimationFrame(applyFrame); clearTimeout(mapTimer); listeners.abort(); observer.disconnect(); };
  }
}
