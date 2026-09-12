import createDOMPurify from 'dompurify';
import { imageURL } from './renderer.js';

// 生HTMLだけに適用する。KaTeXなどアプリ生成の位置指定と混ぜない。
const rawPurify = createDOMPurify(window);
const tags = ['a','abbr','b','bdi','bdo','blockquote','br','caption','cite','code','col','colgroup',
  'dd','del','details','dfn','div','dl','dt','em','figcaption','figure','h1','h2','h3','h4','h5','h6',
  'hr','i','img','ins','kbd','li','mark','ol','p','pre','q','rp','rt','ruby','s','samp','small',
  'span','strong','sub','summary','sup','table','tbody','td','th','thead','tfoot','time','tr','u','ul','var','wbr'];
const properties = /^(color|background-color|font-size|font-weight|font-style|text-align|text-decoration|line-height|border(?:-(?:top|right|bottom|left))?(?:-(?:color|width|style))?|border-radius|padding(?:-(?:top|right|bottom|left))?|margin(?:-(?:top|right|bottom|left))?|width|max-width|height|max-height)$/;
rawPurify.addHook('afterSanitizeAttributes', node => {
  if (!node.style) return;
  const safe = document.createElement('span').style;
  for (const property of node.style) {
    const value = node.style.getPropertyValue(property);
    // CSSOMで復号後に検査。URL・変数・負の余白・巨大値を使ったUIへの干渉を許可しない。
    if (!properties.test(property) || /url|var\(|expression|\\|@|calc\(|[<>]/i.test(value)) continue;
    if (/-\d/.test(value) || [...value.matchAll(/(?<![\w#])(\d*\.?\d+)([a-z]+|%)/gi)]
      .some(([, n, unit]) => !['px','em','rem','vh','vw','%'].includes(unit.toLowerCase()) || Number(n) > (unit === 'px' ? 1000 : unit === '%' ? 100 : 20))) continue;
    if (property === 'line-height' && /^\d*\.?\d+$/.test(value) && Number(value) > 4) continue;
    safe.setProperty(property, value);
  }
  node.removeAttribute('style');
  if (safe.cssText) node.setAttribute('style', safe.cssText);
});
export function cleanHTML(value, inline, context) {
  // inlineの閉じタグは単体sanitizeすると消える。許可タグだけをそのまま戻す。
  const closing = /^<\/([a-z][a-z0-9]*)\s*>$/i.exec(value);
  if (inline && closing) return tags.includes(closing[1].toLowerCase()) ? value : '';
  const fragment = rawPurify.sanitize(value, {
    ALLOWED_TAGS: tags,
    ALLOWED_ATTR: ['href','src','alt','title','style','id','width','height','colspan','rowspan','scope','start','reversed','open','dir','lang','datetime'],
    ALLOW_DATA_ATTR: false, ALLOW_ARIA_ATTR: false, RETURN_DOM_FRAGMENT: true,
    // srcは後段で既存の画像ローダーへ渡す。危険なschemeはimageURLで拒否する。
    ADD_URI_SAFE_ATTR: ['src'],
  });
  for (const node of fragment.querySelectorAll('[id]')) node.id = 'html-' + node.id;
  for (const node of fragment.querySelectorAll('a[href^="#"]')) node.setAttribute('href', '#html-' + node.getAttribute('href').slice(1));
  for (const image of fragment.querySelectorAll('img')) {
    const path = image.getAttribute('src') || '';
    const url = imageURL(path, context);
    if (url && path) image.setAttribute('src', url); else image.removeAttribute('src');
    image.setAttribute('referrerpolicy', 'no-referrer');
  }
  const holder = document.createElement('div'); holder.append(fragment);
  if (inline && /^<[a-z][^>]*>$/i.test(value.trim())) {
    const first = holder.firstElementChild;
    if (!first) return '';
    // 閉じられていない開始タグの構造はMarkdown側に保持させる。
    return first.outerHTML.slice(0, first.outerHTML.indexOf('>') + 1);
  }
  return holder.innerHTML;
}
