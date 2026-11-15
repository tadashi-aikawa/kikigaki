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
    report();
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once:true });
  else start();
  addEventListener('message', event => {
    const data = event.data;
    if (event.source !== parent || data?.kind !== 'hit' || !Number.isFinite(data.x) || !Number.isFinite(data.y)) return;
    const link = document.elementFromPoint(data.x, data.y)?.closest('a[data-link]');
    // 返すのは親が振った番号だけ。リンク先はこの中に持たない。
    send({ kind:'hit', seq:data.seq, link:link ? Number(link.getAttribute('data-link')) : null });
  });
})();
