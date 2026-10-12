// WKWebViewのcallAsyncJavaScriptへ渡す関数本文。通常の描画資産には同梱しない。
const canvas=document.querySelector('.board-canvas'),stage=canvas.querySelector('.diagram-stage');
canvas.querySelector('[data-label="戻す"]').click();
await new Promise(requestAnimationFrame);
let reads=0,writes=0;
const original=Element.prototype.getBoundingClientRect;
Element.prototype.getBoundingClientRect=function(){reads++;return original.call(this);};
const observer=new MutationObserver(records=>writes+=records.length);
observer.observe(stage,{attributes:true,attributeFilter:['style']});
const intervals=[],costs=[];
let previous;
const event=(type,options)=>canvas.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerId:1,button:0,...options}));
const gesture=(type,scale)=>{
  const e=new Event(type,{bubbles:true,cancelable:true});
  Object.defineProperties(e,{scale:{value:scale},clientX:{value:450},clientY:{value:425}});canvas.dispatchEvent(e);
};
if(input==='drag')event('pointerdown',{clientX:400,clientY:400});
if(input==='pinch')gesture('gesturestart',1);
try {
  for(let frame=0;frame<150;frame++) {
    const now=await new Promise(requestAnimationFrame);
    if(frame>=30)intervals.push(now-previous);
    previous=now;
    const start=performance.now();
    // 同一フレームに届く高頻度入力を8回。画面外へ流れ続けないよう方向を交互にする。
    for(let i=0;i<8;i++) {
      const sign=frame%2 ? -1 : 1;
      if(input==='scroll')canvas.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaX:sign*2,deltaY:sign*2}));
      if(input==='drag')event('pointermove',{clientX:400+(frame%2 ? 0 : 32)+i*4,clientY:400+(frame%2 ? 0 : 32)+i*4});
      if(input==='pinch')gesture('gesturechange',1+(frame%2 ? 0.01 : 0.02)+i*0.001);
    }
    if(frame>=30)costs.push(performance.now()-start);
  }
  if(input==='drag')event('pointerup',{clientX:400,clientY:400});
  if(input==='pinch')gesture('gestureend',1);
  await new Promise(requestAnimationFrame);
  const stats=values=>{const sorted=values.toSorted((a,b)=>a-b);return {
    mean:values.reduce((a,b)=>a+b,0)/values.length,p50:sorted[Math.floor(sorted.length*0.5)],
    p95:sorted[Math.floor(sorted.length*0.95)],max:sorted.at(-1)};};
  return {nodes:count,input,frames:intervals.length,interval:stats(intervals),inputCost:stats(costs),
    slowFrames:intervals.filter(ms=>ms>25).length,geometryReads:reads,transformWrites:writes};
} finally { Element.prototype.getBoundingClientRect=original;observer.disconnect(); }
