import { invoke } from '@tauri-apps/api/core';

type Location={id:string;country:string;city:string;host:string};
type PingResult={id:string;ping:number|null};
type ConnState={connected:boolean;state:string;latency_ms?:number|null};
type Verified={fingerprint:string;verifiedAt:number;latency:number|null};

const VERIFIED_KEY='milmit-real-connect-latency-v1';
const TTL=10*60*1000;
const CONNECT_DEADLINE_MS=12000;
const PREFLIGHT_BATCH=24;
let running=false;
let cancelled=false;

function loadVerified():Record<string,Verified>{try{return JSON.parse(localStorage.getItem(VERIFIED_KEY)||'{}')}catch{return{}}}
function saveVerified(v:Record<string,Verified>){localStorage.setItem(VERIFIED_KEY,JSON.stringify(v))}
function normalizeRoute(s:string){return s.replace(/\s+uid\s+\d+/g,'').replace(/\s+cache\s*/g,' ').replace(/\s+/g,' ').trim()}
async function fingerprint(){try{const raw=await invoke<string>('helper_action',{action:'route-explain',args:['1.1.1.1']});const v=JSON.parse(raw);return normalizeRoute(String(v?.results?.[0]?.route||''))}catch{return''}}
function sleep(ms:number){return new Promise(r=>setTimeout(r,ms))}

async function waitDisconnected(maxMs=2200){const end=Date.now()+maxMs;while(Date.now()<end){try{const s=await invoke<ConnState>('connection_state');if(!s.connected&&!['PREPARING','DISCOVERING','IKE','AUTHENTICATING','TUNNEL_ESTABLISHED','VERIFYING_DATA','FALLBACK','CONNECTING','CANCELLING'].includes((s.state||'').toUpperCase()))return}catch{}await sleep(120)}}

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
    // Publish latency only after this exact location completes authentication + data-path verification.
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

async function quickPreflight(all:Location[]){
  const out=new Map<string,number|null>();
  for(let offset=0;offset<all.length;offset+=PREFLIGHT_BATCH){
    if(cancelled)break;
    const batch=all.slice(offset,offset+PREFLIGHT_BATCH);
    setProgress(`Quick precheck · ${Math.min(offset+batch.length,all.length)}/${all.length}`);
    const rows=await invoke<PingResult[]>('ping_locations_batch',{items:batch.map(x=>({id:x.id,host:x.host}))}).catch(()=>[] as PingResult[]);
    for(const row of rows)out.set(row.id,row.ping);
    // Missing preflight results are deliberately kept as null and STILL receive a real connection test.
    for(const loc of batch)if(!out.has(loc.id))out.set(loc.id,null);
    await sleep(25);
  }
  return out;
}

async function startRealScan(btn:HTMLButtonElement){
  if(running){cancelled=true;btn.textContent='Stopping…';return}
  const current=await invoke<ConnState>('connection_state').catch(()=>({connected:false,state:'DISCONNECTED'} as ConnState));
  if(current.connected&&!window.confirm('Real Scan temporarily disconnects the active VPN while it verifies every configured location one by one. Continue?'))return;
  running=true;cancelled=false;window.dispatchEvent(new CustomEvent('milmit-real-scan-state',{detail:{running:true}}));btn.classList.add('is-running');btn.innerHTML='<span class="real-scan-dot"></span><span>Stop real scan</span>';
  try{
    if(current.connected){await invoke('cancel_connect').catch(()=>{});await waitDisconnected()}
    const fp=await fingerprint();
    const raw=await invoke<Location[]>('list_locations');
    // Test every unique configured location, not just one representative per country.
    const seen=new Set<string>();
    const all=raw.filter(loc=>{if(!loc?.id||seen.has(loc.id))return false;seen.add(loc.id);return true});
    if(!all.length){setProgress('Real scan · no locations found');return}
    const preMap=await quickPreflight(all);
    if(cancelled)return;
    // Reachable-looking endpoints go first for speed; null/unreachable preflight locations are last,
    // but they are NOT skipped because only a real tunnel test is authoritative.
    const ordered=[...all].sort((a,b)=>(preMap.get(a.id)??Number.MAX_SAFE_INTEGER)-(preMap.get(b.id)??Number.MAX_SAFE_INTEGER));
    const verified=loadVerified();let done=0,ok=0,failed=0,cached=0;
    for(const loc of ordered){
      if(cancelled)break;
      done++;
      const old=verified[loc.id];
      if(old&&fp&&old.fingerprint===fp&&Date.now()-old.verifiedAt<TTL){
        ok++;cached++;setProgress(`Real scan · ${done}/${ordered.length} · ${ok} verified`);continue;
      }
      const quick=preMap.get(loc.id)??null;
      setProgress(`${loc.country} · ${loc.city} · connecting · ${done}/${ordered.length}`);
      const latency=await realConnect(loc,quick);
      if(latency!=null&&fp){verified[loc.id]={fingerprint:fp,verifiedAt:Date.now(),latency};ok++}
      else {failed++;/* Preserve an older valid record until TTL/network change; verified-latency owns expiry. */}
      saveVerified(verified);
      await sleep(80);
    }
    saveVerified(verified);
    const suffix=cached?` · ${cached} cached`:'';
    setProgress(cancelled?`Stopped · ${done}/${ordered.length} tested · ${ok} verified`:`Done · ${ordered.length}/${ordered.length} tested · ${ok} verified · ${failed} failed${suffix}`);
    window.setTimeout(clearProgress,5200);
  }catch(e){console.warn('Full Real Scan:',e);setProgress(`Real scan failed: ${String(e).slice(0,80)}`);window.setTimeout(clearProgress,5000)}finally{
    running=false;cancelled=false;window.dispatchEvent(new CustomEvent('milmit-real-scan-state',{detail:{running:false}}));btn.classList.remove('is-running');btn.innerHTML='✓ Real scan';
    await invoke('cancel_connect').catch(()=>{});await waitDisconnected();
  }
}

function install(){ensureStyles();const bar=toolbar();if(!bar||bar.querySelector('.real-scan-btn'))return;const btn=document.createElement('button');btn.className='real-scan-btn';btn.type='button';btn.title='Actually connect, authenticate and verify every configured VPN location before showing latency';btn.innerHTML='✓ Real scan';btn.addEventListener('click',()=>void startRealScan(btn));bar.appendChild(btn)}

new MutationObserver(()=>requestAnimationFrame(install)).observe(document.documentElement,{subtree:true,childList:true});
window.addEventListener('DOMContentLoaded',install);install();
