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
        event.preventDefault(); this.deselect();
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
  reset() { this.deselect(); this.states.clear(); }
  // 再描画中に古いDOMを操作しない。選択キーと状態は次のDOMへ引き継ぐ。
  detach() { this.selected?.cancel(); this.selected = null; }
  deselect() {
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
  attach(holder, key) {
    const state = this.states.get(key) || { scale:1, x:0, y:0, window:false, selected:false };
    this.states.set(key, state);
    holder.dataset.diagramKey = key;
    holder.tabIndex = 0;
    holder.setAttribute('aria-label', 'Mermaid図。クリックで選択し、拡大縮小・移動。Escで解除');
    const stage = document.createElement('div'); stage.className = 'diagram-stage';
    stage.append(...holder.childNodes); holder.append(stage);
    // 新しいSVGの自然寸法を、transformを掛ける前に測る。高さはDOMごとの値で、
    // 再描画へ持ち越さない。選択時はこの高さを使い、周囲の配置を変えない。
    // 折り畳まれた節ではDOMの高さが0になる。自然幅はviewBox幅と同じなので、
    // その場合はSVGの自然高を使い、節を開いたあとも図を潰さない。
    let height = holder.getBoundingClientRect().height || stage.querySelector('svg').viewBox.baseVal.height;
    const svg = stage.querySelector('svg');
    const edges = document.createElement('div'); edges.className = 'diagram-edges';
    edges.setAttribute('aria-hidden', 'true');
    for (const side of ['left', 'right', 'top', 'bottom']) {
      const edge = document.createElement('span'); edge.className = 'diagram-edge';
      edge.dataset.side = side; edges.append(edge);
    }
    holder.append(edges);
    const viewport = () => {
      // WebKitのpageZoom下ではclientHeightの整数丸めが数pxずれる。
      // はみ出しの無い図の下端へ誤って印を出さないよう、実際の枠を使う。
      const frame = holder.getBoundingClientRect();
      const scrollbar = !state.window && holder.scrollWidth > holder.clientWidth + 1
        ? Math.max(0, holder.offsetHeight - holder.clientHeight) : 0;
      return { width:frame.width, height:frame.height - scrollbar };
    };
    const bounds = () => {
      const frame = holder.getBoundingClientRect(), box = svg.getBoundingClientRect();
      return { x:box.left - frame.left, y:box.top - frame.top, width:box.width, height:box.height };
    };
    const updateEdges = () => {
      const size = viewport(), visible = diagramOverflow(bounds(), size);
      // 絶対配置の層をスクロール量だけ戻し、未選択でも窓の端へ固定する。
      edges.style.left = holder.scrollLeft + 'px'; edges.style.top = holder.scrollTop + 'px';
      edges.style.width = size.width + 'px'; edges.style.height = size.height + 'px';
      for (const edge of edges.children) edge.hidden = !visible[edge.dataset.side];
    };
    const naturalBounds = () => {
      const box = bounds();
      return { x:(box.x - state.x) / state.scale, y:(box.y - state.y) / state.scale,
        width:box.width / state.scale, height:box.height / state.scale };
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
      fitDiagram(state, naturalBounds(), viewport()); apply();
    });
    const reset = button('戻す', '図を等倍・初期位置へ戻す', () => {
      state.scale = 1; state.x = state.y = 0; apply();
    });
    controls.append(minus, label, plus, fit, reset); holder.append(controls);
    let drag = null, gesture = null, suppressClick = false;
    const apply = () => {
      if (state.window) {
        holder.classList.add('diagram-window'); holder.style.height = height + 'px';
      }
      stage.style.transform = `translate(${state.x}px, ${state.y}px) scale(${state.scale})`;
      label.dataset.label = Math.round(state.scale * 100) + '%';
      label.setAttribute('aria-label', '図の倍率 ' + label.dataset.label);
      minus.disabled = state.scale <= MIN_DIAGRAM_SCALE;
      plus.disabled = state.scale >= MAX_DIAGRAM_SCALE;
      updateEdges();
      this.positionControls();
    };
    const zoom = (scale, point) => { zoomDiagram(state, scale, point); apply(); };
    const point = event => {
      const rect = holder.getBoundingClientRect();
      return { x:event.clientX - rect.left, y:event.clientY - rect.top };
    };
    const cancel = () => {
      if (drag && holder.hasPointerCapture(drag.id)) holder.releasePointerCapture(drag.id);
      drag = gesture = null; holder.classList.remove('diagram-dragging');
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
      state.selected = true; this.selected = { holder, state, cancel, controls };
      holder.classList.add('diagram-selected'); apply();
      holder.focus({ preventScroll:true });
    };
    holder.addEventListener('click', event => {
      if (suppressClick) { event.preventDefault(); event.stopImmediatePropagation(); suppressClick = false; return; }
      if (!state.selected) {
        // 最初のクリックは選択。選択後のカードのクリックは既存の見出し移動を使う。
        event.preventDefault(); event.stopImmediatePropagation(); select();
      }
    }, true);
    holder.addEventListener('pointerdown', event => {
      if (!state.selected || event.button !== 0 || event.target.closest('.diagram-controls')) return;
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
      state.x += dx; state.y += dy; drag.x = event.clientX; drag.y = event.clientY; apply();
    };
    const end = event => {
      if (!drag || drag.id !== event.pointerId) return;
      suppressClick = drag.moved; cancel();
    };
    // capture前に図の外へ出た場合も、同じドラッグを終えられる。
    const listeners = new AbortController();
    holder.addEventListener('scroll', updateEdges, { passive:true, signal:listeners.signal });
    const observer = new ResizeObserver(() => { updateEdges(); this.positionControls(); });
    observer.observe(holder); observer.observe(svg);
    document.addEventListener('pointermove', move, { signal:listeners.signal });
    document.addEventListener('pointerup', end, { signal:listeners.signal });
    holder.addEventListener('pointercancel', cancel);
    holder.addEventListener('lostpointercapture', cancel);
    holder.addEventListener('wheel', event => {
      if (!state.selected || event.target.closest('.diagram-controls')) return;
      // ⌘の文字倍率はネイティブのメニューへ任せる。
      if (event.metaKey) return;
      event.preventDefault();
      if (event.ctrlKey) {
        // Safariのgesture経路と同時に来ても倍率を二重に掛けない。
        if (!gesture) zoom(state.scale * Math.exp(-event.deltaY * 0.01), point(event));
      } else {
        const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? holder.clientHeight : 1;
        state.x -= event.deltaX * unit; state.y -= event.deltaY * unit; apply();
      }
    }, { passive:false });
    holder.addEventListener('gesturestart', event => {
      if (!state.selected || event.target.closest('.diagram-controls')) return;
      event.preventDefault(); gesture = { scale:state.scale, point:point(event) };
    }, { passive:false });
    holder.addEventListener('gesturechange', event => {
      if (!state.selected || !gesture) return;
      event.preventDefault(); zoom(gesture.scale * event.scale, gesture.point);
    }, { passive:false });
    holder.addEventListener('gestureend', event => {
      if (!gesture) return;
      event.preventDefault(); gesture = null;
    }, { passive:false });
    apply();
    if (state.selected) select();
    return () => { cancel(); listeners.abort(); observer.disconnect(); };
  }
}
