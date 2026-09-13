import test from 'node:test';
import assert from 'node:assert/strict';
import { createRenderer, withoutFrontmatter, imageURL } from './renderer.js';
import { changedEntries, UpdateHighlighter } from './updates.js';
import { isTimeline, wrapTimeline } from './timeline.js';
const render = text => createRenderer().render(withoutFrontmatter(text), { context: 'test' });
test('変更行は追加と書換えだけで移動と削除は光らせない', () => {
  const entries = values => values.map(key => ({ key }));
  assert.deepEqual(changedEntries(entries(['a','b','same','same']), entries(['new','b','a','same','same','same'])).map(e => e.key), ['new','same']);
  assert.deepEqual(changedEntries(entries(['a','b']), entries(['a'])), []);
});
test('基準がある間は依頼中の編集を累積で強調し、置き直しと切替で捨てる', () => {
  const entries = values => values.map(key => ({ key }));
  const keys = plan => plan.entries.map(e => e.key);
  const updates = new UpdateHighlighter();
  // 基準が無ければ従来どおり直前の描画との差分。初回は光らせない
  assert.deepEqual(updates.plan(entries(['a'])), { entries: [], persist: false });
  assert.deepEqual(keys(updates.plan(entries(['a','b']))), ['b']);
  assert.deepEqual(keys(updates.plan(entries(['a','b','c']))), ['c']);
  // 依頼の送信で基準を置く。以後は基準との差分を累積し、時間で消さない
  updates.mark();
  const first = updates.plan(entries(['a','b2','c']));
  assert.deepEqual([keys(first), first.persist], [['b2'], true]);
  assert.deepEqual(keys(updates.plan(entries(['a','b2','c2']))), ['b2','c2']);
  assert.deepEqual(keys(updates.plan(entries(['a2','b2','c2']))), ['a2','b2','c2']);
  // 編集の開始で置き直すと、それまでの強調は消える
  updates.mark();
  assert.deepEqual(updates.plan(entries(['a2','b2','c2'])), { entries: [], persist: true });
  assert.deepEqual(keys(updates.plan(entries(['a2','b3','c2']))), ['b3']);
  // 表示対象の切替で基準を捨て、次の描画は初回として扱う
  updates.reset();
  assert.deepEqual(updates.plan(entries(['x','y'])), { entries: [], persist: false });
  assert.deepEqual(keys(updates.plan(entries(['x','y','z']))), ['z']);
});
test('本文が無いうちに置いた基準は最初の描画を基準にする', () => {
  const entries = values => values.map(key => ({ key }));
  const updates = new UpdateHighlighter();
  updates.mark();
  assert.deepEqual(updates.plan(entries(['a','b'])), { entries: [], persist: true });
  assert.deepEqual(updates.plan(entries(['a','b','c'])).entries.map(e => e.key), ['c']);
});

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
test('timelineの期間と出来事だけを枠幅で改行し他の行は変えない', () => {
  const fits = text => [...text].length <= 6;
  const source = 'timeline\n    title 振り返りと展望とその先\n    section 長い区分の名前です\n    %% コメント: 長い長い長い長い\n    1年前 : テーマ「ユーザーからビルダーへ」 : 自身は<br/>まだビルダーではなかった\n      : 次の年 : 時刻 12:30 に集合\n    accTitle: 長い長い長い長い長い\n';
  assert.equal(wrapTimeline(source, fits), 'timeline\n    title 振り返りと展望とその先\n    section 長い区分の名前です\n    %% コメント: 長い長い長い長い\n    1年前 : テーマ「ユー<br>ザーからビル<br>ダーへ」 : 自身は<br>まだビルダー<br>ではなかった\n      : 次の年 : 時刻 12:<br>30 に集合\n    accTitle: 長い長い長い長い長い\n');
  assert.equal(wrapTimeline('timeline\n  2024 : 短い\n', fits), 'timeline\n  2024 : 短い\n');
  assert.equal(wrapTimeline('timeline\n  2025 : エージェントと組織AI : abcdefghij\n', fits), 'timeline\n  2025 : エージェント<br>と組織AI : abcdef<br>ghij\n');
  // 期間の「:」はMermaidが受け付けないためエンティティ記法へ置き換える。幅は置換前で測り、出来事の「12:30」は変えない
  assert.equal(wrapTimeline('timeline\n    21:39 : 録音を開始 : 12:30\n    1:2:3 : 相談\n', fits), 'timeline\n    21#colon;39 : 録音を開始 : 12:30\n    1#colon;2#colon;3 : 相談\n');
  assert.equal(wrapTimeline('timeline\n    12:30:45 : 長い\n', fits), 'timeline\n    12#colon;30#colon;<br>45 : 長い\n');
  assert.equal(wrapTimeline('timeline\n    2024 # メモ\n', fits), 'timeline\n    2024 # メモ\n');
  assert.ok(isTimeline('%%{init: {}}%%\n\ntimeline\n  a : b'));
  assert.ok(isTimeline('---\ntitle: x\n---\ntimeline LR\n  a : b'));
  assert.ok(!isTimeline('flowchart LR\n  A --> B'));
  assert.ok(!isTimeline('mindmap\n  root((timeline))'));
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
