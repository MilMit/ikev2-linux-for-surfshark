import { invoke } from '@tauri-apps/api/core';

let replaying=false;
let cancelling=false;

function phase(){return (document.querySelector('.hero-area h2')?.textContent||'').trim().toUpperCase();}
function connectButton(){return document.querySelector<HTMLButtonElement>('.home-actions > .connect-btn, .home-actions > .disconnect-btn');}
function decorate(){
  const btn=connectButton();
  if(!btn)return;
  const p=phase();
  if(p==='CONNECTING'){
    btn.disabled=false;
    btn.dataset.milmitCancel='1';
    btn.classList.remove('connect-btn');
    btn.classList.add('disconnect-btn');
    if(!btn.textContent?.includes('Cancel'))btn.innerHTML='<span style="font-size:18px">×</span>Cancel connection';
  }else if(p!=='CANCELLING'){
    delete btn.dataset.milmitCancel;
  }
}
async function cancel(){
  if(cancelling)return;
  cancelling=true;
  const btn=connectButton();
  if(btn){btn.disabled=true;btn.innerHTML='<span style="font-size:18px">×</span>Cancelling…';}
  try{await invoke<string>('cancel_connect');}catch(e){console.warn('MilMit cancel_connect:',e)}finally{cancelling=false;}
}

document.addEventListener('click',async e=>{
  if(replaying)return;
  const target=e.target as HTMLElement|null;
  const btn=target?.closest<HTMLButtonElement>('[data-milmit-cancel="1"]');
  if(btn&&phase()==='CONNECTING'){
    e.preventDefault();e.stopPropagation();
    await cancel();
    return;
  }
  const loc=target?.closest<HTMLButtonElement>('.location-row,.quick-location');
  if(loc&&phase()==='CONNECTING'){
    e.preventDefault();e.stopPropagation();
    await cancel();
    replaying=true;
    try{loc.click();}finally{setTimeout(()=>{replaying=false},0)}
  }
},true);

const observer=new MutationObserver(()=>decorate());
observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true,attributes:true,attributeFilter:['disabled','class']});
setInterval(decorate,350);
decorate();
