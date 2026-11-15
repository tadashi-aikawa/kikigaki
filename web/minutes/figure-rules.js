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

// 図と付箋の名前・種類として使えるか。長さはUTF-8のバイト数で数え、空白と制御文字を含まない。
// 数え方をアプリの検証と揃えるため、文字数ではなくバイト数にする。
const encoder = new TextEncoder();
export function validName(value, max) {
  if (typeof value !== 'string' || /[\s\p{Cc}]/u.test(value)) return false;
  const bytes = encoder.encode(value).length;
  return bytes >= 1 && bytes <= max;
}
// 付箋の文。空白を1つに畳む。更新の強調はこの文で、文が変わった付箋を見分ける。
export function noteText(text) { return text.replace(/\s+/g, ' ').trim(); }

// 更新の強調で図を突き合わせる名前。figures は描く順の { name, at } で、at は見出しのIDと節の中の順番。
// 議事録の中で重ならない名前の図は名前で引く。重なる名前の図と名前の無い図は at で引き、名前も添える。
// 名前を添えるので、重なったままの名前を別の名前へ変えたときも、付箋は新しいものとして光る。
export function figureKeys(figures) {
  const counts = new Map();
  for (const { name } of figures) if (name) counts.set(name, (counts.get(name) || 0) + 1);
  return figures.map(({ name, at }) => counts.get(name) === 1
    ? JSON.stringify(['name', name]) : JSON.stringify(['at', at, name]));
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
