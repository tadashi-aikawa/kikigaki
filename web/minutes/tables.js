// ペイン幅を超える表だけ、広い列から等しく詰める最大公平配分を置く。
// ブラウザ任せの自動配分は日本語の短い見出しを1文字幅まで潰す (CJKは文字間で改行できるため
// min-contentが1文字になり、長い列と同率で詰められる)。AI返事側の MarkdownBodyView.fit と同じ考え方。

// 列の下限。表の文字14px×3文字ぶんに枡の左右の余白20pxと罫2pxを足した外形。
export const MIN_COLUMN = 64;

/// 自然幅の合計が予算を超えるときだけ配分を返す。収まる表には null を返し、何も置かない。
/// 下限を割ってもなお超える表は、そのまま .table-wrap が横スクロールする。
export function fitColumns(naturals, budget, minimum = MIN_COLUMN) {
  const total = naturals.reduce((sum, width) => sum + width, 0);
  if (!(budget > 0) || !naturals.length || total <= budget) return null;
  const widths = naturals.slice();
  let remaining = budget, left = naturals.length;
  // 狭い列から決める。自然幅が取り分より小さい列は自然幅のまま残り、余りが広い列へ回る。
  const order = naturals.map((_, index) => index).sort((a, b) => naturals[a] - naturals[b] || a - b);
  for (const index of order) {
    const share = Math.max(minimum, remaining / left);
    widths[index] = Math.min(naturals[index], share);
    remaining -= widths[index];
    left--;
  }
  return widths;
}

/// 描画後とペイン幅の変化のたびに呼ぶ。前回置いた colgroup は測る前に必ず外す。
export function layoutTables(root) {
  for (const wrap of root.querySelectorAll('.table-wrap')) {
    const table = wrap.querySelector(':scope > table');
    // 折りたたまれた表は測れない。置いた幅をそのまま残し、開いたときに測り直す。
    if (!table || !wrap.clientWidth) continue;
    table.querySelector(':scope > colgroup[data-fit]')?.remove();
    table.style.tableLayout = ''; table.style.width = '';
    const row = table.rows[0];
    if (!row?.cells.length) continue;
    // 自然幅 (max-content) を測る。折り返しを止めて器の上限も外し、先頭行の枡の外形を読む。
    // 自動layoutでは列幅が全行で等しいので、先頭行だけで列の最大幅になる。
    table.style.maxWidth = 'none'; table.style.width = 'max-content';
    table.classList.add('measuring');
    const naturals = [...row.cells].map(cell => cell.getBoundingClientRect().width);
    // 罫を重ねる表では、外周の罫が枡の外形からはみ出して表の幅になる。その差を予算から引く。
    const slack = Math.max(0, table.getBoundingClientRect().width - naturals.reduce((sum, w) => sum + w, 0));
    table.classList.remove('measuring');
    table.style.maxWidth = ''; table.style.width = '';
    const widths = fitColumns(naturals, wrap.clientWidth - slack);
    if (!widths) continue;
    const group = document.createElement('colgroup');
    group.dataset.fit = '';
    for (const width of widths) {
      const col = document.createElement('col');
      col.style.width = width.toFixed(2) + 'px';
      group.append(col);
    }
    // colgroup は文字もstyle属性を持つ枡も足さないため、更新強調のキーと検索の索引を変えない。
    table.prepend(group);
    table.style.tableLayout = 'fixed';
    table.style.width = widths.reduce((sum, width) => sum + width, 0).toFixed(2) + 'px';
  }
}
