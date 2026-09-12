import MarkdownIt from 'markdown-it';
import footnote from 'markdown-it-footnote';
import tasks from 'markdown-it-task-lists';
import texmath from 'markdown-it-texmath';
import katex from 'katex';

export function withoutFrontmatter(source) {
  const text = source.replace(/^\uFEFF/, '').replace(/\r\n?/g, '\n');
  return text.replace(/^---[ \t]*\n[\s\S]*?\n---[ \t]*(?:\n|$)/, '');
}

export function imageURL(path, context) {
  if (/^https?:\/\//i.test(path)) return path;
  if (/^[a-z][a-z\d+.-]*:/i.test(path) && !path.startsWith('file:///')) return '';
  return 'minutes-image://' + context + '/?path=' + encodeURIComponent(path);
}

export function createRenderer() {
  const md = new MarkdownIt({ html: false, linkify: true, breaks: true })
    .use(footnote).use(tasks, { enabled: false })
    .use(texmath, { engine: katex, delimiters: ['dollars', 'brackets'],
      katexOptions: { trust: false, strict: 'ignore', maxExpand: 1000, maxSize: 20 } });
  const escape = md.utils.escapeHtml;
  md.inline.ruler.before('link', 'wiki', (state, silent) => {
    const start = state.pos, embed = state.src.startsWith('![[', start);
    if (!embed && !state.src.startsWith('[[', start)) return false;
    const end = state.src.indexOf(']]', start + (embed ? 3 : 2));
    if (end < 0) return false;
    const raw = state.src.slice(start, end + 2);
    if (raw.includes('\n')) return false;
    if (!silent) {
      const parts = raw.slice(embed ? 3 : 2, -2).replace(/\\\|/g, '|').split('|');
      const target = parts.shift(), label = parts.join('|') || target;
      const token = state.push('wiki', '', 0);
      token.meta = { target, label, embed, raw };
    }
    state.pos = end + 2;
    return true;
  });
  md.renderer.rules.wiki = (tokens, i, options, env) => {
    const { target, label, embed, raw } = tokens[i].meta;
    if (embed) {
      if (!/\.(png|jpe?g|gif|webp|svg|avif|bmp|tiff?)(?:[?#]|$)/i.test(target)) return escape(raw);
      const size = /^(\d{1,4})(?:x(\d{1,4}))?$/.exec(label);
      const width = size ? ' width="' + Math.min(4096, Number(size[1])) + '"' : '';
      return '<img referrerpolicy="no-referrer" src="' + escape(imageURL(target, env.context)) + '" alt="' + escape(target) + '"' + width + '>';
    }
    if (target.startsWith('#')) return '<a href="#' + escape(target.slice(1)) + '">' + escape(label) + '</a>';
    return escape(label);
  };
  md.renderer.rules.image = (tokens, i, options, env, self) => {
    const token = tokens[i], original = token.attrGet('src') || '';
    // markdown-itがURL化したローカルパスをここで一度だけ復号する。wikilinkは元から生のパス。
    let path = original;
    if (!/^https?:\/\//i.test(path) && !path.startsWith('file:///')) {
      try { path = decodeURIComponent(path); } catch { /* 不完全な%はファイル名のまま扱う。 */ }
    }
    const url = imageURL(path, env.context);
    if (!url) return escape('![' + token.content + '](' + original + ')');
    token.attrSet('src', url);
    token.attrSet('referrerpolicy', 'no-referrer');
    token.attrSet('alt', self.renderInlineAsText(token.children, options, env) || original);
    return self.renderToken(tokens, i, options);
  };
  const fence = md.renderer.rules.fence;
  md.renderer.rules.fence = (tokens, i, options, env, self) => {
    const token = tokens[i], language = token.info.trim().toLowerCase();
    if (language === 'mermaid' || language === 'svg')
      return '<pre class="' + language + '-source">' + escape(token.content) + '</pre>';
    if (language === 'math' || language === 'latex') {
      try { return katex.renderToString(token.content, { displayMode: true, trust: false, maxExpand: 1000, maxSize: 20 }); }
      catch { return '<pre>' + escape(token.content) + '</pre>'; }
    }
    return fence(tokens, i, options, env, self);
  };
  // HTML全体を有効にせず、閉じたSVGブロックだけを画像候補として取り出す。
  md.block.ruler.before('html_block', 'svg_block', (state, start, end, silent) => {
    const at = state.bMarks[start] + state.tShift[start];
    if (!state.src.startsWith('<svg', at)) return false;
    const match = /^<svg\b[\s\S]*?<\/svg>[ \t]*(?=\n|$)/.exec(state.src.slice(at));
    if (!match) return false;
    if (silent) return true;
    const token = state.push('svg_block', '', 0);
    token.content = match[0]; token.map = [start, start + match[0].split('\n').length];
    state.line = token.map[1]; return true;
  }, { alt: ['paragraph'] });
  md.renderer.rules.svg_block = (tokens, i) => '<pre class="svg-source">' + escape(tokens[i].content) + '</pre>';
  md.renderer.rules.table_open = () => '<div class="table-wrap"><table>\n';
  md.renderer.rules.table_close = () => '</table></div>\n';
  md.core.ruler.after('inline', 'document_structure', state => {
    const ids = new Map();
    for (let i = 0; i < state.tokens.length; i++) {
      const token = state.tokens[i];
      if (token.type === 'heading_open') {
        const inline = state.tokens[i + 1];
        const explicit = /\s+\{#([^{}\s]+)\}\s*$/.exec(inline.content);
        if (explicit) {
          inline.content = inline.content.slice(0, explicit.index);
          inline.children = []; md.inline.parse(inline.content, md, state.env, inline.children);
        }
        const label = inline.children.filter(t => t.type === 'text' || t.type === 'code_inline').map(t => t.content).join('');
        const base = explicit?.[1] || label.toLowerCase().trim().replace(/\s+/g, '-').replace(/[^\p{L}\p{N}_-]/gu, '') || 'section';
        const count = ids.get(base) || 0; ids.set(base, count + 1);
        token.attrSet('id', 'heading-' + base + (count ? '-' + count : ''));
        token.attrSet('data-heading', explicit?.[1] || label);
      }
      if (token.type === 'blockquote_open') {
        const inline = state.tokens[i + 2];
        const match = inline?.type === 'inline' && /^\[!([A-Za-z]+)\][+-]?(?:[ \t]+([^\n]*))?(?:\n|$)/.exec(inline.content);
        if (!match) continue;
        let depth = 1, close = i + 1;
        for (; close < state.tokens.length; close++) {
          if (state.tokens[close].type === 'blockquote_open') depth++;
          if (state.tokens[close].type === 'blockquote_close' && --depth === 0) break;
        }
        // 上のループではclose以外のtokenでdepthを減らさない。
        token.tag = 'aside'; token.attrSet('class', 'callout'); token.attrSet('data-kind', match[1].toLowerCase());
        if (state.tokens[close]) state.tokens[close].tag = 'aside';
        inline.content = inline.content.slice(match[0].length);
        inline.children = []; md.inline.parse(inline.content, md, state.env, inline.children);
        const title = new state.Token('callout_title', '', 0); title.content = match[2] || match[1];
        state.tokens.splice(i + 1, 0, title);
      }
    }
  });
  md.renderer.rules.callout_title = (tokens, i) => '<div class="callout-title">' + escape(tokens[i].content) + '</div>';
  return md;
}
