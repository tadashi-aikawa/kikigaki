// SVGの図の規則のうち、DOMに触れないもの。Nodeのテストから直接読める。
// 設計時の決定は docs/records/svg-canvas-design.md、現行仕様は docs/svg-canvas.md。

// 表示する大きさ。SVGの中の座標 (viewBox) とは別に決める。
// width="200" と viewBox="0 0 1000 500" の図は、従来の画像と同じく幅200で出す。
export function figureSize({ width, height, viewBox }) {
  // 割合・0以下・数でない値は、無いものとして扱う。
  const length = value => {
    const match = /^\s*(\d*\.?\d+)(?:px)?\s*$/i.exec(value ?? '');
    const number = match ? Number(match[1]) : NaN;
    return Number.isFinite(number) && number > 0 ? number : null;
  };
  const box = (viewBox ?? '').trim().split(/[\s,]+/).map(Number);
  const view = box.length === 4 && box.every(Number.isFinite) && box[2] > 0 && box[3] > 0
    ? { width:box[2], height:box[3] } : null;
  const w = length(width), h = length(height);
  if (w && h) return { width:w, height:h };
  if (w && view) return { width:w, height:w * view.height / view.width };
  if (h && view) return { width:h * view.width / view.height, height:h };
  if (view) return view;
  return { width:300, height:150 };
}

// 図の原文が同じかを比べる短い印。暗号の強さは要らない。
export function figureHash(source) {
  let hash = 0x811c9dc5;
  for (let i = 0; i < source.length; i++) hash = Math.imul(hash ^ source.charCodeAt(i), 0x01000193);
  return (hash >>> 0).toString(16) + ':' + source.length;
}

// CSSの値が、図の外のファイルを読まないかを確かめる。残してよい url() は同じ図の中の参照だけ。
// 戻り値は残す値。外すときは null。base は親ページのURLで、CSSOMが絶対URLへ直した参照を見分ける。
// 分かっている書き方を外す形なので、漏れはありうる。漏れて読めるのはHTTP・HTTPSの画像までで、
// ローカルのファイルはアプリが minutes-image: のhostで止める。
export function safeCSSValue(property, value, base) {
  // 変数と image-set() は、url() を書かずにURLを組み立てられる。
  if (property.startsWith('--')) return null;
  if (/var\(|image-set\(|image\(|cross-fade\(|element\(|src\(|attr\(|expression|\\|@/i.test(value)) return null;
  let safe = true;
  const cleaned = value.replace(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)/gi, (_, double, single, bare) => {
    const target = (double ?? single ?? bare ?? '').trim();
    if (target.startsWith('#')) return 'url("' + target + '")';
    // CSSOMは参照を親ページのURLへ解決して返すことがある。親ページ自身の断片だけを同じ図の参照として戻す。
    const hash = target.indexOf('#');
    if (base && hash > 0 && target.slice(0, hash) === base) return 'url("' + target.slice(hash) + '")';
    safe = false; return '';
  });
  // 置き換えで拾えなかった url( が残るなら、読み切れない書き方として外す。
  if (!safe || /url\(/i.test(cleaned.replace(/url\("#[^"]*"\)/g, ''))) return null;
  return cleaned;
}
