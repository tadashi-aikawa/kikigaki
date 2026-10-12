// WKWebViewのテストと独立した実フレーム計測で同じ監視を使う。
window.observeDiagramUpdate = async (source, board, during = () => {}) => {
  const root = document.getElementById('minutes'), previous = root.querySelector('.diagram');
  const result = { samples:0, frames:0, previousSamples:0, sourceSamples:0, emptySamples:0, temporarySVGSamples:0 };
  let pending = true, frame;
  const sample = () => {
    result.samples++;
    if (previous?.isConnected) result.previousSamples++;
    if (root.querySelector('.mermaid-source')) result.sourceSamples++;
    if (!root.querySelector('.diagram svg')) result.emptySamples++;
    // Mermaidが本文の外へ出す途中のSVGも、等倍・拡大の両方で隠れているか見る。
    if ([...document.querySelectorAll('body > div svg')].some(svg =>
      getComputedStyle(svg).visibility !== 'hidden' && svg.getClientRects().length)) result.temporarySVGSamples++;
  };
  const observer = new MutationObserver(() => {
    sample();
    if (pending && previous?.isConnected) during(previous);
  });
  observer.observe(document.body, { childList:true, subtree:true });
  const tick = () => { sample(); result.frames++; if (pending) frame = requestAnimationFrame(tick); };
  frame = requestAnimationFrame(tick);
  try {
    sample();
    // Swift側の実描画ticketと衝突させず、DOMの監視だけで完了を待つ。
    const rendering = window.minutes.render(source, 'test', false, -1, null, board, board);
    // 最初のawaitへ入った時点も測り、旧図がまだ表示されていることを数える。
    sample();
    await rendering;
    sample();
    return result;
  } finally {
    pending = false; observer.disconnect(); cancelAnimationFrame(frame);
  }
};
void 0;
