import { invoke } from '@tauri-apps/api/core';

type Location={id:string;country:string;city:string;host:string};
type ConnState={connected:boolean;state:string;latency_ms?:number|null};
type Verified={fingerprint:string;verifiedAt:number;latency:number|null};

const KEY='milmit-real-connect-latency-v1';
const TTL=10*60*1000;
let locations:Location[]=[];
let currentFingerprint='';
let lastConnected=false;
let preConnectFingerprint='';
let masking=false;
let maskQueued=false;

function load():Record<string,Verified>{try{return JSON.parse(localStorage.getItem(KEY)||'{}')}catch{return{}}}
function save(v:Record<string,Verified>){localStorage.setItem(KEY,JSON.stringify(v))}
function selectedId(){return localStorage.getItem('milmit-selected-location')||''}
function normalizeRoute(s:string){return s.replace(/\s+uid\s+\d+/g,'').replace(/\s+cache\s*/g,' ').replace(/\s+/g,' ').trim()}
function setText(el:HTMLElement,text:string){if(el.textContent!==text)el.textContent=text}

async function physicalFingerprint(){
  try{
    const raw=await invoke<string>('helper_action',{action:'route-explain',args:['1.1.1.1']});
    const v=JSON.parse(raw);
    const route=String(v?.results?.[0]?.route||'');
    return normalizeRoute(route);
  }catch{return ''}
}

function cachedLatency(id:string):number|null{
  for(const key of ['milmit-location-pings-v3','milmit-location-pings-v2']){
    try{const obj=JSON.parse(localStorage.getItem(key)||'{}');const n=obj?.values?.[id];if(typeof n==='number'&&Number.isFinite(n))return Math.round(n)}catch{}
  }
  return null;
}

function findLocationForRow(row:HTMLElement):Location|undefined{
  const city=(row.querySelector('.loc-main b')?.textContent||'').trim();
  const group=row.closest('.country-group');
  const country=(group?.querySelector(':scope > summary b')?.textContent||'').trim();
  return locations.find(x=>x.city===city&&x.country===country);
}

function maskLatencies(){
  if(masking)return;masking=true;
  try{
    const records=load();
    document.querySelectorAll<HTMLElement>('.location-row').forEach(row=>{
      const loc=findLocationForRow(row);const badge=row.querySelector<HTMLElement>('.latency');if(!loc||!badge)return;
      const r=records[loc.id];const ok=!!r&&!!currentFingerprint&&r.fingerprint===currentFingerprint&&Date.now()-r.verifiedAt<TTL;
      if(ok&&typeof r.latency==='number'){
        setText(badge,`${r.latency} ms`);
        if(badge.dataset.realVerified!=='1')badge.dataset.realVerified='1';
        if(badge.title!=='Verified by a successful VPN tunnel and data-path test on this network')badge.title='Verified by a successful VPN tunnel and data-path test on this network';
      }else{
        setText(badge,'—');
        if(badge.dataset.realVerified)delete badge.dataset.realVerified;
        if(badge.title!=='Not fully verified on this network yet')badge.title='Not fully verified on this network yet';
      }
    });
    document.querySelectorAll<HTMLElement>('.country-group').forEach(group=>{
      const badge=group.querySelector<HTMLElement>(':scope > summary .country-latency');if(!badge)return;
      const vals=[...group.querySelectorAll<HTMLElement>('.location-row .latency[data-real-verified="1"]')].map(x=>Number((x.textContent||'').match(/\d+/)?.[0])).filter(Number.isFinite);
      const text=vals.length?`${Math.min(...vals)} ms`:'—';setText(badge,text);
      const title=vals.length?'Best fully verified location on this network':'No fully verified location on this network yet';if(badge.title!==title)badge.title=title;
    });
  }finally{masking=false}
}
function queueMask(){if(maskQueued)return;maskQueued=true;requestAnimationFrame(()=>{maskQueued=false;maskLatencies()})}

async function poll(){
  try{
    const state=await invoke<ConnState>('connection_state');
    const phase=(state.state||'').toUpperCase();
    const connecting=['PREPARING','IKE','AUTHENTICATING','TUNNEL_ESTABLISHED','VERIFYING_DATA','FALLBACK','CONNECTING'].includes(phase);
    if(connecting&&!preConnectFingerprint){preConnectFingerprint=currentFingerprint||await physicalFingerprint()}
    if(!state.connected&&!connecting){const fp=await physicalFingerprint();if(fp)currentFingerprint=fp}
    if(state.connected&&!lastConnected){
      const id=selectedId();const fp=preConnectFingerprint||currentFingerprint;
      if(id&&fp){const all=load();all[id]={fingerprint:fp,verifiedAt:Date.now(),latency:cachedLatency(id)??state.latency_ms??null};save(all)}
      preConnectFingerprint='';
    }
    if(!state.connected&&lastConnected)preConnectFingerprint='';
    if(!state.connected&&(phase==='FAILED'||phase==='BLOCKED')){const id=selectedId();if(id){const all=load();delete all[id];save(all)}}
    lastConnected=state.connected;queueMask();
  }catch{}
}

function installStyles(){const s=document.createElement('style');s.textContent=`.latency[data-real-verified="1"],.country-latency{transition:opacity .18s ease}.latency[data-real-verified="1"]::before{content:'✓ ';font-size:.8em;opacity:.8}`;document.head.appendChild(s)}

void invoke<Location[]>('list_locations').then(v=>{locations=v;queueMask()}).catch(()=>{});
void physicalFingerprint().then(v=>{currentFingerprint=v;queueMask()});
new MutationObserver(queueMask).observe(document.documentElement,{subtree:true,childList:true,characterData:true});
installStyles();
setInterval(()=>void poll(),1200);
void poll();
