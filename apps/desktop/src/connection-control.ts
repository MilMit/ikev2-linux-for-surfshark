import { invoke } from '@tauri-apps/api/core';

let replaying=false;
let cancelling=false;
let decorateQueued=false;

function phase(){return (document.querySelector('.hero-area h2')?.textContent||'').trim().toUpperCase();}
function connectButton(){return document.querySelector<HTMLButtonElement>('.home-actions > .connect-btn, .home-actions > .disconnect-btn');}
function decorate(){
  decorateQueued=false;
  const btn=connectButton();
  if(!btn)return;
  const p=phase();
  if(p==='CONNECTING'){
    if(btn.disabled)btn.disabled=false;
    if(btn.dataset.milmitCancel!=='1')btn.dataset.milmitCancel='1';
    if(btn.classList.contains('connect-btn'))btn.classList.remove('connect-btn');
    if(!btn.classList.contains('disconnect-btn'))btn.classList.add('disconnect-btn');
    if(!btn.textContent?.includes('Cancel connection'))btn.innerHTML='<span style="font-size:18px">×</span>Cancel connection';
  }else if(p!=='CANCELLING'&&btn.dataset.milmitCancel){
    delete btn.dataset.milmitCancel;
  }
}
function queueDecorate(){
  if(decorateQueued)return;
  decorateQueued=true;
  requestAnimationFrame(decorate);
}
async function cancel(){
  if(cancelling)return;
  cancelling=true;
  const btn=connectButton();
  if(btn){btn.disabled=true;btn.innerHTML='<span style="font-size:18px">×</span>Cancelling…';}
  try{await invoke<string>('cancel_connect');}catch(e){console.warn('MilMit cancel_connect:',e)}finally{cancelling=false;queueDecorate();}
}

document.addEventListener('click',e=>{
  if(replaying)return;
  const target=e.target as HTMLElement|null;
  const btn=target?.closest<HTMLButtonElement>('[data-milmit-cancel="1"]');
  if(btn&&phase()==='CONNECTING'){
    e.preventDefault();e.stopPropagation();
    void cancel();
    return;
  }
  const loc=target?.closest<HTMLButtonElement>('.location-row,.quick-location');
  if(loc&&phase()==='CONNECTING'){
    e.preventDefault();e.stopPropagation();
    void cancel();
    replaying=true;
    try{loc.click();}finally{queueMicrotask(()=>{replaying=false})}
  }
},true);

const observer=new MutationObserver(()=>queueDecorate());
observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true});
setInterval(queueDecorate,500);
queueDecorate();
