// 議事録のSVGの図を描くiframeの中で動く。親ページとはpostMessageだけでやりとりする。
// このiframeはポインタのイベントを受けない。クリックは親が座標で渡してくる。
// 2回読まれても壊れないよう、状態はwindowに1つだけ持つ。
(() => {
  const send = value => parent.postMessage(value, '*');
  // 2回目に読まれたら、親は捨てる種類の知らせだけを出す。実WebKitのテストが、子のCSPの抜けを見つけるのに使う。
  if (window.__kikigakiCanvas) { send({ kind:'duplicate' }); return; }
  window.__kikigakiCanvas = true;
  // 画像の成否。読み込みのイベントは親へ伝播しないので、captureで拾う。
  // このスクリプトは本文より先に動くので、取りこぼさない。
  const settled = new WeakMap();
  const isImage = element => element instanceof SVGImageElement || element instanceof HTMLImageElement;
  const settle = (image, ok) => { if (!settled.has(image)) { settled.set(image, ok); report(); } };
  for (const [type, ok] of [['load', true], ['error', false]]) {
    document.addEventListener(type, event => { if (isImage(event.target)) settle(event.target, ok); }, true);
  }
  let images = null, reported = false, timer = null;
  const report = (force = false) => {
    if (reported || !images) return;
    const pending = images.filter(image => !settled.has(image));
    if (pending.length && !force) return;
    reported = true; clearTimeout(timer);
    // 待つ上限を超えた画像は、読めなかったものに数える。
    send({ kind:'ready', failed:images.filter(image => settled.get(image) !== true).length, images:images.length });
  };
  const start = () => {
    images = [...document.querySelectorAll('image,img')].filter(image =>
      image.getAttribute('href') || image.getAttribute('src'));
    // 読み込みのイベントが来ない画像もある。デコードの完了でも成否を拾う。
    for (const image of images) image.decode?.().then(() => settle(image, true), () => settle(image, false));
    timer = setTimeout(() => report(true), 8000);
    // 本文が揃ったことを先に知らせる。親は、覚えていた更新の強調をここで渡す。
    send({ kind:'loaded' });
    report();
  };
  // 更新で光らせる付箋。付箋の外形の上に、本文の更新の強調と同じ淡い紫を重ねる。
  // 図のCSSは文書の全体に効くので、重ねる層はshadow DOMの中に描く。図の規則が層の中へ届かない。
  // 層の置き場の要素だけは図の規則に当たりうるので、見え方に関わる値を直に、!importantで固める。
  // 四角は付箋の画面上の座標系へ合わせるので、回転した付箋にも沿う。
  const SVG = 'http://www.w3.org/2000/svg';
  let overlay = null;
  const highlight = ids => {
    overlay?.remove(); overlay = null;
    const root = document.querySelector('body > svg');
    if (!ids.length || !root) return;
    const layer = document.createElementNS(SVG, 'svg');
    for (const id of ids) {
      const element = document.getElementById(id);
      if (!(element instanceof SVGGraphicsElement) || !root.contains(element)) continue;
      let box, m;
      try { box = element.getBBox(); m = element.getScreenCTM(); } catch { continue; }
      if (!m || (!box.width && !box.height)) continue;
      const rect = document.createElementNS(SVG, 'rect');
      for (const [name, value] of Object.entries({ x:box.x, y:box.y, width:box.width, height:box.height,
        transform:`matrix(${m.a} ${m.b} ${m.c} ${m.d} ${m.e} ${m.f})`, fill:'#9b72c6', 'fill-opacity':0.21,
        stroke:'#9b72c6', 'stroke-opacity':0.44, 'stroke-width':3, 'vector-effect':'non-scaling-stroke' })) {
        rect.setAttribute(name, String(value));
      }
      layer.append(rect);
    }
    if (!layer.childElementCount) return;
    layer.setAttribute('style', 'position:absolute;left:0;top:0;width:100%;height:100%;overflow:visible');
    overlay = document.createElement('div');
    // 先に all:initial で全部の値を初期値へ戻す。transform とは別に効く scale・translate・rotate も戻る。
    for (const [name, value] of Object.entries({ all:'initial', display:'block', position:'fixed', inset:'0',
      width:'100%', height:'100%', 'z-index':'2147483647', 'pointer-events':'none' })) {
      overlay.style.setProperty(name, value, 'important');
    }
    overlay.attachShadow({ mode:'closed' }).append(layer);
    document.body.append(overlay);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once:true });
  else start();
  addEventListener('message', event => {
    const data = event.data;
    if (event.source !== parent) return;
    if (data?.kind === 'highlight' && Array.isArray(data.ids) && data.ids.every(id => typeof id === 'string')) {
      highlight(data.ids); return;
    }
    if (data?.kind !== 'hit' || !Number.isFinite(data.x) || !Number.isFinite(data.y)) return;
    const link = document.elementFromPoint(data.x, data.y)?.closest('a[data-link]');
    // 返すのは親が振った番号だけ。リンク先はこの中に持たない。
    send({ kind:'hit', seq:data.seq, link:link ? Number(link.getAttribute('data-link')) : null });
  });
})();
