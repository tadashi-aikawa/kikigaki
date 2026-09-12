import test from 'node:test';
import assert from 'node:assert/strict';
import { createRenderer, withoutFrontmatter, imageURL } from './renderer.js';
const render = text => createRenderer().render(withoutFrontmatter(text), { context: 'test' });

test('frontmatterとコード内の記法を保持', () => {
  assert.equal(withoutFrontmatter('\uFEFF---\r\ntitle: a\r\n---\r\n# 本文'), '# 本文');
  assert.match(withoutFrontmatter('---\ntitle: a'), /title/);
  assert.match(render('`[[名前|別名]]`'), /<code>\[\[名前\|別名\]\]<\/code>/);
  assert.match(render('```\n![x](a.png)\n```'), /!\[x\]\(a.png\)/);
});
test('見出しIDの重複と表内wikilink', () => {
  const html = render('# 同じ\n\n# 同じ\n\n## 章 {#jump}\n\n[[a|**別名**]]\n\n| 列 |\n|---|\n| [[a\\|名前]] |');
  assert.match(html, /id="heading-同じ"/); assert.match(html, /id="heading-同じ-1"/);
  assert.match(html, /id="heading-jump"/); assert.match(html, /\*\*別名\*\*/);
  assert.match(html, /<td>名前<\/td>/);
});
test('脚注とcalloutとチェックボックス', () => {
  const html = render('本文[^a]\n\n[^a]: 補足\n\n> [!NOTE] 注意\n> **本文**\n>\n> - 内側\n\n- [x] 済\n  - 子\n- [ ] 未');
  assert.match(html, /footnotes/); assert.match(html, /<aside class="callout"/);
  assert.match(html, /callout-title">注意/); assert.match(html, /<strong>本文/);
  assert.match(html, /<\/aside>/); assert.match(html, /type="checkbox"/);
  assert.doesNotMatch(html, /\[!NOTE\]/);
});
test('数式と図を処理しHTMLはsanitizer未指定なら文字で残す', () => {
  const html = render('$x^2$\n\n$$\nx+y\n$$\n\n```mermaid\nflowchart LR\n A-->B\n```\n\n<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>\n\n<script>alert(1)</script>');
  assert.match(html, /katex/); assert.match(html, /mermaid-source/); assert.match(html, /svg-source/);
  assert.doesNotMatch(html, /<script>/); assert.match(html, /&lt;script&gt;/);
});
test('MySTの3形式と入れ子を描き通常のコードを保持', () => {
  for (const [open, close] of [[':::{note}', ':::'], [':::note', ':::'], ['```{warning}', '```']]) {
    const html = render(open + '\n**中身**\n\n- 項目\n' + close);
    assert.match(html, /<aside class="callout"/); assert.match(html, /<strong>中身<\/strong>/);
    assert.match(html, /<li>項目/); assert.doesNotMatch(html, /language-/);
  }
  assert.equal((render('::::{note}\n外\n\n:::{tip}\n内\n:::\n::::').match(/<aside/g) || []).length, 2);
  assert.match(render('```text\n:::{note}\nコード\n:::\n```'), /<code class="language-text">/);
  assert.doesNotMatch(render(':::{note}\n閉じ忘れ'), /<aside/);
  const code = render(':::{note}\n```text\n:::\n```\n続き\n:::');
  assert.match(code, /<code class="language-text">:::/);
  assert.match(code, /<p>続き<\/p>\n<\/aside>/);
});
test('画像の専用URLと不正scheme', () => {
  assert.equal(imageURL('javascript:alert(1)', 'ctx'), '');
  assert.equal(imageURL('https://example.com/a.png', 'ctx'), 'https://example.com/a.png');
  assert.match(render('![[画像 a.png|200]]'), /width="200"/);
  assert.match(render('![図](<画像 a.png>)'), /minutes-image:\/\/test/);
  assert.match(render('![[別ノート]]'), /!\[\[別ノート\]\]/);
});
