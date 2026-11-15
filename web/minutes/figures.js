import createDOMPurify from 'dompurify';
import { imageURL } from './renderer.js';
import { figureSize, figureHash, safeCSSValue } from './figure-rules.js';

// 議事録のSVGの図を、切り離したiframeで描くための準備。親ページで動く。
// 設計時の決定は docs/records/svg-canvas-design.md、現行仕様は docs/svg-canvas.md。

const SVG = 'http://www.w3.org/2000/svg', XLINK = 'http://www.w3.org/1999/xlink';

const purify = createDOMPurify(window);
// 図の中に要らない文書要素。埋め込み・フォーム・文書の設定を外す。
const forbidden = ['script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'meta', 'link', 'base',
  'form', 'input', 'button', 'textarea', 'select', 'option', 'optgroup', 'datalist', 'output',
  'audio', 'video', 'source', 'track', 'picture', 'canvas', 'dialog', 'template', 'slot', 'noscript', 'portal'];
const pageBase = () => location.href.split('#')[0];

function cleanDeclarations(style, base) {
  const kept = [];
  for (const property of [...style]) {
    const value = safeCSSValue(property, style.getPropertyValue(property), base);
    if (value === null) continue;
    kept.push(property + ':' + value + (style.getPropertyPriority(property) ? ' !important' : ''));
  }
  return kept.join(';');
}
function cleanRules(rules, base) {
  let text = '';
  for (const rule of rules) {
    if (rule instanceof CSSStyleRule) {
      const body = cleanDeclarations(rule.style, base);
      if (body) text += rule.selectorText + '{' + body + '}';
    } else if (rule instanceof CSSKeyframesRule) {
      let frames = '';
      for (const frame of rule.cssRules) {
        const body = cleanDeclarations(frame.style, base);
        if (body) frames += frame.keyText + '{' + body + '}';
      }
      text += '@keyframes ' + CSS.escape(rule.name) + '{' + frames + '}';
    } else if (rule instanceof CSSMediaRule) {
      text += '@media ' + rule.conditionText + '{' + cleanRules(rule.cssRules, base) + '}';
    } else if (rule instanceof CSSSupportsRule) {
      text += '@supports ' + rule.conditionText + '{' + cleanRules(rule.cssRules, base) + '}';
    }
    // @import・@font-face・そのほかの規則は外す。
  }
  return text;
}
function cleanStyleSheet(text, base) {
  // CSSOMで読んでから確かめる。エスケープした書き方を、文字列の検査で取りこぼさない。
  try {
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(text);
    return cleanRules(sheet.cssRules, base);
  } catch { return ''; }
}

// 原文を無害化し、iframeへ渡すSVGと、親が持つ情報を作る。描けない原文は null。
export function prepareFigure(source, context) {
  const body = purify.sanitize(source, {
    USE_PROFILES:{ svg:true, svgFilters:true, html:true },
    ADD_TAGS:['foreignObject', 'use', 'image', 'a', 'style', 'animate', 'set', 'animateTransform', 'animateMotion', 'mpath', 'textPath'],
    FORBID_TAGS:forbidden, FORBID_ATTR:['srcset', 'sizes', 'ping', 'target', 'nonce', 'srcdoc', 'action', 'formaction'],
    // DOMPurifyは既定で foreignObject の中のHTMLを外す。文の折り返しに要るので通す。
    // 出力はsandboxとCSPの中でだけ描くので、ここをすり抜けたscriptも動かない。
    HTML_INTEGRATION_POINTS:{ foreignobject:true, 'annotation-xml':true },
    // file:/// は本文の画像と同じく画像のパスとして受ける。独自のschemeはここで外れる。
    ALLOWED_URI_REGEXP:/^(?:(?:https?|mailto|file):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i,
    RETURN_DOM:true,
  });
  const svg = body.firstElementChild;
  if (svg?.namespaceURI !== SVG || svg.localName !== 'svg') return null;
  const base = pageBase(), probe = document.createElement('span').style, links = [];
  let localImages = 0;
  const reference = element => {
    const value = element.getAttribute('href') ?? element.getAttributeNS(XLINK, 'href');
    element.removeAttributeNS(XLINK, 'href'); element.removeAttribute('xlink:href');
    return value;
  };
  const image = (element, name, written) => {
    if (written === null) return;
    const path = written.trim();
    const url = /^data:/i.test(path) ? path : imageURL(path, context);
    if (!url) { element.removeAttribute(name); return; }
    if (url.startsWith('minutes-image:')) localImages++;
    element.setAttribute(name, url);
  };
  for (const element of [svg, ...svg.querySelectorAll('*')]) {
    const name = element.localName, inSVG = element.namespaceURI === SVG;
    if (inSVG && name === 'image') image(element, 'href', reference(element));
    else if (!inSVG && name === 'img') {
      image(element, 'src', element.getAttribute('src'));
      element.setAttribute('referrerpolicy', 'no-referrer'); element.removeAttribute('loading');
    } else if (name === 'a') {
      // リンク先は親が持ち、iframeへは番号だけを渡す。iframeの中にリンク先を残さない。
      const href = reference(element);
      element.removeAttribute('href');
      if (href) { element.setAttribute('data-link', String(links.length)); links.push(href); }
    } else if (element.hasAttribute('href') || element.hasAttributeNS(XLINK, 'href') || element.hasAttribute('xlink:href')) {
      // use・フィルタの画像・textPathなどは、同じ図の中の参照だけを残す。
      const value = reference(element);
      if (value?.startsWith('#')) element.setAttribute('href', value); else element.removeAttribute('href');
    }
    if (!inSVG && name !== 'img') element.removeAttribute('src');
    // アニメーションで、参照やCSSを後から書き換えさせない。
    if (inSVG && ['animate', 'set', 'animateTransform', 'animateMotion'].includes(name)) {
      const target = (element.getAttribute('attributeName') || '').toLowerCase();
      const values = ['to', 'from', 'by', 'values'].map(key => element.getAttribute(key) || '').join(' ');
      if (/^(?:href|xlink:href|src|srcset|style)$/.test(target) || /url|\\|var\(|image/i.test(values)) { element.remove(); continue; }
    }
    if (name === 'style') {
      element.textContent = cleanStyleSheet(element.textContent, base);
      continue;
    }
    if (element.style && element.hasAttribute('style')) {
      const text = cleanDeclarations(element.style, base);
      if (text) element.setAttribute('style', text); else element.removeAttribute('style');
    }
    // fill・filter・clip-path などの表示の属性もCSSとして読まれる。CSSOMに通してから確かめる。
    for (const attribute of [...element.attributes]) {
      if (attribute.name === 'style' || attribute.name === 'href' || attribute.name === 'src') continue;
      if (!/url|\\|var\(|image/i.test(attribute.value)) continue;
      probe.cssText = '';
      try { probe.setProperty(attribute.name, attribute.value); } catch { continue; }
      const parsed = probe.getPropertyValue(attribute.name);
      if (!parsed) continue;
      const value = safeCSSValue(attribute.name, parsed, base);
      if (value === null) element.removeAttribute(attribute.name); else element.setAttribute(attribute.name, value);
    }
  }
  return {
    markup:svg.outerHTML, links, localImages,
    size:figureSize({ width:svg.getAttribute('width'), height:svg.getAttribute('height'), viewBox:svg.getAttribute('viewBox') }),
    name:svg.getAttribute('id') || '', hash:figureHash(source),
  };
}

// iframeへ入れる文書。SVGが書いたスクリプトは、nonceを持たないので子のCSPが止める。
export function figureDocument(markup, nonce = crypto.randomUUID()) {
  const csp = "default-src 'none'; script-src 'nonce-" + nonce + "'; style-src 'unsafe-inline'; img-src minutes-image: https: http: data:";
  return '<!doctype html><html><head><meta charset="utf-8">'
    + '<meta http-equiv="Content-Security-Policy" content="' + csp + '">'
    + '<meta name="referrer" content="no-referrer">'
    + '<style>html,body{margin:0;height:100%;overflow:hidden;background:transparent;font-family:-apple-system,BlinkMacSystemFont,"Hiragino Sans",sans-serif}'
    + 'body>svg{display:block;width:100%;height:100%}</style>'
    + '<script nonce="' + nonce + '" src="minutes-app://bundle/canvas.js"></' + 'script>'
    + '</head><body>' + markup + '</body></html>';
}
