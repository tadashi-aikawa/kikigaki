// DEBUG計測器だけが読み込む。配布資産には同梱しない。
window.boardPerf?.stop();
const canvas = document.querySelector('.board-canvas');
if (!canvas) throw new Error('board canvas missing');
const stage = canvas.querySelector('.diagram-stage');
canvas.querySelector('[data-label="戻す"]').click();
await new Promise(requestAnimationFrame);
const map = canvas.querySelector('.board-minimap');
const drawing = map.querySelector('svg > svg, svg > use');
if (variant === 'detailed') {
  const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
  use.setAttribute('href', '#' + stage.querySelector('svg').id);
  use.setAttribute('pointer-events', 'none');
  drawing.replaceWith(use);
} else if (variant === 'none') {
  // 非表示だけを切り替える。本体の100ms更新処理は3条件とも同じ。
  map.style.display = 'none';
}
stage.style.willChange = layer ? 'transform' : 'auto';
const intervals = [], events = [], transforms = [];
let last, frame, lastInputTimestamp, measuring = false;
const tick = now => {
  if (measuring && last !== undefined) intervals.push(now - last);
  last = now;
  frame = requestAnimationFrame(tick);
};
frame = requestAnimationFrame(tick);
const receive = event => {
  if (!measuring) return;
  lastInputTimestamp = performance.timeOrigin + event.timeStamp;
  events.push({type:event.type, received:Date.now(),
    timestamp:performance.timeOrigin + event.timeStamp, trusted:event.isTrusted,
    x:event.clientX, y:event.clientY, dx:event.deltaX, dy:event.deltaY});
};
for (const type of ['wheel','pointerdown','pointermove','pointerup']) canvas.addEventListener(type, receive);
const observer = new MutationObserver(() => {
  if (measuring) transforms.push({time:Date.now(), inputTimestamp:lastInputTimestamp, value:stage.style.transform});
});
observer.observe(stage, {attributes:true, attributeFilter:['style']});
window.boardPerf = {
  begin() { last = undefined; measuring = true; },
  finish() {
    measuring = false;
    return {intervals, events, transforms, devicePixelRatio, pageWidth:innerWidth, pageHeight:innerHeight,
      mapVisible:!map.hidden && getComputedStyle(map).display !== 'none',
      canvasConnected:canvas.isConnected, canvasCurrent:canvas === document.querySelector('.board-canvas'),
      willChange:getComputedStyle(stage).willChange,
      svgWidth:stage.querySelector('svg').getBoundingClientRect().width,
      svgHeight:stage.querySelector('svg').getBoundingClientRect().height};
  },
  stop() { cancelAnimationFrame(frame); observer.disconnect();
    for (const type of ['wheel','pointerdown','pointermove','pointerup']) canvas.removeEventListener(type, receive);
  }
};
const r = canvas.getBoundingClientRect();
return {x:r.left + r.width * 0.55, y:r.top + r.height * 0.5};
