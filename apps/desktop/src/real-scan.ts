import { invoke } from '@tauri-apps/api/core';

type Location={id:string;country:string;city:string;host:string};
type PingResult={id:string;ping:number|null};
type ConnState={connected:boolean;state:string;latency_ms?:number|null};
type Verified={fingerprint:string;verifiedAt:number;latency:number|null};

const VERIFIED_KEY='milmit-real-connect-latency-v1';
const SCAN_FLAG='milmit-real-scan-running';
const TTL=10*60*1000;
const CONNECT_DEADLINE_MS=12000;
let running=false;
let cancelled=false;

function loadVerified():Record<string,Verified>{try{return JSON.parse(localStorage.getItem(VERIFIED_KEY)||'{}')}catch{return{}}}
function saveVerified(v:Record<string,Verified>){localStorage.setItem(VERIFIED_KEY,JSON.stringify(v))}
function normalizeRoute(s:string){return s.replace(/\s+uid\s+\d+/g,'').replace(/\s+cache\s*/g,' ').replace(/\s+/g,' ').trim()}
async function fingerprint(){try{const raw=await invoke<string>('helper_action',{action:'route-explain',args:['1.1.1.1']});const v=JSON.parse(raw);const route=normalizeRoute(String(v?.results?.[0]?.route||''));if(!route||/milmitxfrm0|table\s+220/i.test(route))return'';return route}catch{return''}}
function sleep(ms:number){return new Promise(r=>setTimeout(r,ms))}

async function waitDisconnected(maxMs=2200){const end=Date.now()+maxMs;while(Date.now()<end){try{const s=await invoke<ConnState>('connection_state');if(!s.connected&&!['PREPARING','IKE','AUTHENTICATING','TUNNEL_ESTABLISHED','VERIFYING_DATA','FALLBACK','CONNECTING','CANCELLING'].includes((s.state||'').toUpperCase()))return}catch{}await sleep(120)}}

async function realConnect(loc:Location,preflightMs:number|null){
  const started=performance.now();
  let timer=0;
  try{
    const connect=invoke<string>('connect_location',{id:loc.id}).then(()=>true).catch(()=>false);
    const timeout=new Promise<boolean>(resolve=>{timer=window.setTimeout(()=>resolve(false),CONNECT_DEADLINE_MS)});
    const completed=await Promise.race([connect,timeout]);
    if(!completed){await invoke('cancel_connect').catch(()=>{});await waitDisconnected();return null}
    const state=await invoke<ConnState>('connection_state').catch(()=>({connected:false,state:'FAILED'} as ConnState));
    if(!state.connected)return null;
    const elapsed=Math.max(1,Math.round(performance.now()-started));
    return preflightMs??state.latency_ms??elapsed;
  }finally{
    if(timer)window.clearTimeout(timer);
    await invoke('cancel_connect').catch(()=>{});
    await waitDisconnected();
  }
}

function ensureStyles(){if(document.getElementById('milmit-real-scan-styles'))return;const s=document.createElement('style');s.id='milmit-real-scan-styles';s.textContent=`
.real-scan-btn{display:inline-flex;align-items:center;gap:7px}.real-scan-btn.is-running{cursor:wait;opacity:.92}.real-scan-dot{width:8px;height:8px;border-radius:50%;background:currentColor;box-shadow:0 0 0 0 currentColor;animation:realScanPulse 1.15s infinite}.real-scan-progress{font-size:12px;opacity:.82;margin-left:auto;white-space:nowrap}@keyframes realScanPulse{60%{box-shadow:0 0 0 7px transparent}}@media(prefers-reduced-motion:reduce){.real-scan-dot{animation:none}}
`;document.head.appendChild(s)}

function toolbar(){return document.querySelector<HTMLElement>('.location-toolbar')}
function setProgress(text:string){let el=document.querySelector<HTMLElement>('.real-scan-progress');if(!el){el=document.createElement('span');el.className='real-scan-progress';toolbar()?.appendChild(el)}el.textContent=text}
function clearProgress(){document.querySelector('.real-scan-progress')?.remove()}

async function startRealScan(btn:HTMLButtonElement){
  if(running){cancelled=true;btn.textContent='Stopping…';return}
  const current=await invoke<ConnState>('connection_state').catch(()=>({connected:false,state:'DISCONNECTED'} as ConnState));
  if(current.connected&&!window.confirm('Fast Real Scan temporarily disconnects the active VPN while it verifies countries one by one. Continue?'))return;
  running=true;cancelled=false;localStorage.setItem(SCAN_FLAG,'1');window.dispatchEvent(new CustomEvent('milmit-real-scan-state',{detail:{running:true}}));btn.classList.add('is-running');btn.innerHTML='<span class="real-scan-dot"></span><span>Stop real scan</span>';
  try{
    if(current.connected){await invoke('cancel_connect').catch(()=>{});await waitDisconnected()}
    let fp='';
    for(let i=0;i<6&&!fp;i++){fp=await fingerprint();if(!fp)await sleep(180)}
    const all=await invoke<Location[]>('list_locations');
    const byCountry=new Map<string,Location[]>();for(const l of all){const a=byCountry.get(l.country)||[];a.push(l);byCountry.set(l.country,a)}
    const reps=[...byCountry.values()].map(v=>v[0]);
    setProgress(`Quick precheck · 0/${reps.length}`);
    const pre=await invoke<PingResult[]>('ping_locations_batch',{items:reps.map(x=>({id:x.id,host:x.host}))}).catch(()=>[] as PingResult[]);
    const preMap=new Map(pre.map(x=>[x.id,x.ping]));
    const ordered=[...reps].sort((a,b)=>(preMap.get(a.id)??999999)-(preMap.get(b.id)??999999));
    const verified=loadVerified();let done=0,ok=0,skipped=0;
    for(const loc of ordered){
      if(cancelled)break;
      done++;const old=verified[loc.id];
      if(old&&fp&&old.fingerprint===fp&&Date.now()-old.verifiedAt<TTL){ok++;setProgress(`Real scan · ${done}/${ordered.length} · ${ok} verified`);continue}
      const quick=preMap.get(loc.id)??null;
      if(quick==null){skipped++;setProgress(`Real scan · ${done}/${ordered.length} · ${ok} verified`);continue}
      setProgress(`${loc.country} · connecting · ${done}/${ordered.length}`);
      const latency=await realConnect(loc,quick);
      if(latency!=null&&fp){verified[loc.id]={fingerprint:fp,verifiedAt:Date.now(),latency};ok++;saveVerified(verified)}
      setProgress(`Real scan · ${done}/${ordered.length} · ${ok} verified`);
      await sleep(80);
    }
    saveVerified(verified);
    setProgress(cancelled?`Stopped · ${ok} verified`:`Done · ${ok} verified${skipped?` · ${skipped} unreachable`:''}`);
    window.setTimeout(clearProgress,4200);
  }catch(e){console.warn('Fast Real Scan:',e);setProgress(`Real scan failed: ${String(e).slice(0,80)}`);window.setTimeout(clearProgress,5000)}finally{
    running=false;cancelled=false;localStorage.removeItem(SCAN_FLAG);window.dispatchEvent(new CustomEvent('milmit-real-scan-state',{detail:{running:false}}));btn.classList.remove('is-running');btn.innerHTML='✓ Real scan';
    await invoke('cancel_connect').catch(()=>{});await waitDisconnected();
  }
}

function install(){ensureStyles();const bar=toolbar();if(!bar||bar.querySelector('.real-scan-btn'))return;const btn=document.createElement('button');btn.className='real-scan-btn';btn.type='button';btn.title='Actually connect, authenticate and verify VPN data before showing latency';btn.innerHTML='✓ Real scan';btn.addEventListener('click',()=>void startRealScan(btn));bar.appendChild(btn)}

new MutationObserver(()=>requestAnimationFrame(install)).observe(document.documentElement,{subtree:true,childList:true});
window.addEventListener('DOMContentLoaded',install);install();
