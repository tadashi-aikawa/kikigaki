// 1文1行の原稿を保ちながら、日本語に接する改行を表示時の空白にしない。
// 段落・表のセル・見出しに適用し、英数字どうしの改行やコードはそのまま残す。
const JAPANESE = /[\u3000-\u30ff\u3400-\u9fff\uf900-\ufaff\uff00-\uffef]/;

function join(node, ctx) {
  const leaves = [];
  function collect(parent) {
    for (const child of parent.children ?? []) {
      if (child.children) collect(child);
      else leaves.push({ node: child, text: ctx.textContent(child) });
    }
  }
  collect(node);

  leaves.forEach(({ node: child, text }, i) => {
    if (child.type !== "text" || !text.includes("\n")) return;
    const value = text.replace(/\n/g, (newline, offset) => {
      const before = offset > 0 ? text[offset - 1] : leaves[i - 1]?.text.slice(-1) ?? "";
      const after = offset < text.length - 1 ? text[offset + 1] : leaves[i + 1]?.text.slice(0, 1) ?? "";
      return JAPANESE.test(before) || JAPANESE.test(after) ? "" : newline;
    });
    if (value !== text) ctx.setProperty(child, "value", value);
  });
}

export const joinJa = {
  name: "join-ja",
  paragraph: join,
  tableCell: join,
  heading: join,
};
