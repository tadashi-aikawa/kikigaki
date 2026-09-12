// Mermaidのtimelineは枠幅150px固定で、空白と <br> でしか折り返さない。日本語文は1語扱いで枠をはみ出すため、
// 描画前に実フォントで幅を測り、収まる位置へ <br> を差し込む。書かれた <br> は残し、<br/> も同じ改行として扱う。
// 対象は期間と出来事だけ。title・section・accTitle・accDescr・コメント行は変えない。
const HEADER = /^\s*(?:timeline\b|title\s|section\s|accTitle\s*:|accDescr\s*[:{]|%%|#|\})/i;
// Mermaidの字句規則に合わせる。期間は行頭から最初の「:」まで(「#」以降はコメント)、出来事は「: 」から次の「: 」の手前まで。
const SEGMENTS = /(^[^#:\n]+)|(:\s+)((?:[^:\n]|:(?!\s))+)/g;

// 先頭のfrontmatter・%%コメント・空行を除いた最初の行が timeline なら対象。
export function isTimeline(source) {
  const lines = source.split('\n');
  let index = 0;
  if (/^\s*---\s*$/.test(lines[0] ?? '')) {
    index = lines.findIndex((line, i) => i > 0 && /^\s*---\s*$/.test(line));
    if (index < 0) return false;
    index += 1;
  }
  const first = lines.slice(index).find(line => !/^\s*(?:%%|$)/.test(line));
  return /^\s*timeline\b/i.test(first ?? '');
}

export function wrapTimeline(source, fits) {
  return source.split('\n').map(line => HEADER.test(line) ? line
    : line.replace(SEGMENTS, (_, period, separator, event) => period ? wrapSegment(period, fits) : separator + wrapSegment(event, fits))).join('\n');
}

function wrapSegment(segment, fits) {
  const leading = segment.match(/^\s*/)[0], trailing = segment.match(/\s*$/)[0];
  const text = segment.slice(leading.length, segment.length - trailing.length);
  if (!text) return segment;
  const lines = text.split(/<br\s*\/?>/i).flatMap(piece => wrapPiece(piece, fits));
  return leading + lines.join('<br>') + trailing;
}

// 英数字の連なりは1語として扱い、「AI」の途中では切らない。1語だけで幅を超えるときは文字で切る。
function wrapPiece(piece, fits) {
  if (!piece || fits(piece)) return [piece];
  const lines = []; let current = '';
  for (const unit of piece.match(/[A-Za-z0-9]+|[\s\S]/g)) {
    if (!current || fits(current + unit)) { current += unit; continue; }
    lines.push(current); current = unit;
  }
  lines.push(current);
  return lines.flatMap(line => fits(line) ? [line] : wrapChars(line, fits));
}

function wrapChars(line, fits) {
  const lines = []; let current = '';
  for (const char of line) {
    if (!current || fits(current + char)) { current += char; continue; }
    lines.push(current); current = char;
  }
  lines.push(current);
  return lines;
}
