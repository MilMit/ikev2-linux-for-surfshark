import { invoke } from '@tauri-apps/api/core';

let replaying=false;
let cancelling=false;
let decorateQueued=false;
let cancelledReadyUntil=0;
let resetTimer=0;

function phase(){return (document.querySelector('.hero-area h2')?.textContent||'').trim().toUpperCase();}
function connectButton(){return document.querySelector<HTMLButtonElement>('.home-actions > .connect-btn, .home-actions > .disconnect-btn');}

function ensureStyles(){
  if(document.getElementById('milmit-connection-control-styles'))return;
  const style=document.createElement('style');
  style.id='milmit-connection-control-styles';
  style.textContent=`
    .milmit-connection-action{position:relative;overflow:hidden;transition:background .28s ease,color .28s ease,transform .22s ease,box-shadow .28s ease,opacity .2s ease!important}
    .milmit-connection-action::after{content:"";position:absolute;inset:0;pointer-events:none;opacity:0;transition:opacity .25s ease}
    .milmit-connection-action.is-connecting{background:#c94d5b!important;color:#fff!important;box-shadow:0 0 0 1px rgba(255,255,255,.06),0 10px 26px rgba(201,77,91,.16)}
    .milmit-connection-action.is-connecting::after{opacity:1;background:linear-gradient(110deg,transparent 20%,rgba(255,255,255,.08) 45%,transparent 70%);transform:translateX(-100%);animation:milmitSweep 1.45s linear infinite}
    .milmit-connection-action.is-cancelling{background:#8a5360!important;color:#fff!important;transform:scale(.985);cursor:wait!important}
    .milmit-connection-action.is-cancelled{background:#31536f!important;color:#e8f3fa!important;transform:scale(.98);box-shadow:0 0 0 1px rgba(255,255,255,.08)}
    .milmit-connection-action.is-ready{background:#57c28b!important;color:#082317!important;animation:milmitReady .42s cubic-bezier(.2,.8,.2,1)}
    .milmit-connection-icon{width:20px;height:20px;display:grid;place-items:center;flex:0 0 20px}
    .milmit-connection-icon.ring{border:2px solid rgba(255,255,255,.38);border-top-color:#fff;border-radius:50%;animation:milmitSpin .72s linear infinite}
    .milmit-connection-icon.cancel{font-size:22px;font-weight:500;line-height:1;transform:translateY(-1px)}
    .milmit-connection-icon.check{font-size:16px;font-weight:900}
    @keyframes milmitSpin{to{transform:rotate(360deg)}}
    @keyframes milmitSweep{to{transform:translateX(100%)}}
    @keyframes milmitReady{0%{transform:scale(.97);filter:brightness(.9)}65%{transform:scale(1.015)}100%{transform:scale(1)}}
    @media (prefers-reduced-motion:reduce){.milmit-connection-action,.milmit-connection-action::after,.milmit-connection-icon{animation:none!important;transition:none!important}}
  `;
  document.head.appendChild(style);
}

function setVisual(btn:HTMLButtonElement,state:'connecting'|'cancelling'|'cancelled'|'ready'){
  ensureStyles();
  btn.classList.add('milmit-connection-action');
  btn.classList.remove('is-connecting','is-cancelling','is-cancelled','is-ready');
  if(state==='connecting'){
    btn.classList.add('is-connecting');
    btn.disabled=false;
    btn.dataset.milmitCancel='1';
    btn.innerHTML='<span class="milmit-connection-icon cancel">×</span><span>Cancel connection</span>';
  }else if(state==='cancelling'){
    btn.classList.add('is-cancelling');
    btn.disabled=true;
    btn.dataset.milmitCancel='1';
    btn.innerHTML='<span class="milmit-connection-icon ring"></span><span>Cancelling…</span>';
  }else if(state==='cancelled'){
    btn.classList.add('is-cancelled');
    btn.disabled=true;
    delete btn.dataset.milmitCancel;
    btn.innerHTML='<span class="milmit-connection-icon check">✓</span><span>Cancelled</span>';
  }else{
    btn.classList.add('is-ready');
    btn.classList.remove('disconnect-btn');
    btn.classList.add('connect-btn');
    btn.disabled=false;
    delete btn.dataset.milmitCancel;
    btn.innerHTML='<span class="milmit-connection-icon">⏻</span><span>Secure my connection</span>';
  }
}

function decorate(){
  decorateQueued=false;
  const btn=connectButton();
  if(!btn)return;
  const p=phase();
  if(cancelling){setVisual(btn,'cancelling');return;}
  if(Date.now()<cancelledReadyUntil){setVisual(btn,'ready');return;}
  if(p==='CONNECTING'){setVisual(btn,'connecting');return;}
  if(p==='CANCELLING'){setVisual(btn,'cancelling');return;}
  delete btn.dataset.milmitCancel;
  btn.classList.remove('milmit-connection-action','is-connecting','is-cancelling','is-cancelled','is-ready');
}
function queueDecorate(){
  if(decorateQueued)return;
  decorateQueued=true;
  requestAnimationFrame(decorate);
}

async function waitForReactReset(maxMs=1800){
  const started=Date.now();
  while(Date.now()-started<maxMs){
    const p=phase();
    if(p!=='CONNECTING'&&p!=='CANCELLING')return;
    await new Promise(r=>setTimeout(r,80));
  }
}

async function cancel(){
  if(cancelling)return;
  cancelling=true;
  window.clearTimeout(resetTimer);
  const btn=connectButton();
  if(btn)setVisual(btn,'cancelling');
  try{
    await invoke<string>('cancel_connect');
    const current=connectButton();
    if(current)setVisual(current,'cancelled');
    await new Promise(r=>setTimeout(r,320));
    await waitForReactReset();
    cancelledReadyUntil=Date.now()+1800;
    const ready=connectButton();
    if(ready)setVisual(ready,'ready');
    resetTimer=window.setTimeout(()=>{cancelledReadyUntil=0;queueDecorate();},1850);
  }catch(e){
    console.warn('MilMit cancel_connect:',e);
    cancelledReadyUntil=Date.now()+900;
  }finally{
    cancelling=false;
    queueDecorate();
  }
}

document.addEventListener('click',e=>{
  if(replaying)return;
  const target=e.target as HTMLElement|null;
  const btn=target?.closest<HTMLButtonElement>('[data-milmit-cancel="1"]');
  if(btn&&(phase()==='CONNECTING'||cancelling)){
    e.preventDefault();e.stopPropagation();
    void cancel();
    return;
  }
  const loc=target?.closest<HTMLButtonElement>('.location-row,.quick-location');
  if(loc&&phase()==='CONNECTING'){
    // Select the new location immediately while the old attempt is cancelled in parallel.
    e.preventDefault();e.stopPropagation();
    void cancel();
    replaying=true;
    try{loc.click();}finally{queueMicrotask(()=>{replaying=false})}
  }
},true);

// React owns the actual connection state. This observer only decorates text/classes
// and intentionally ignores attributes to avoid the old self-triggering freeze loop.
const observer=new MutationObserver(()=>queueDecorate());
observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true});
setInterval(queueDecorate,400);
ensureStyles();
queueDecorate();
