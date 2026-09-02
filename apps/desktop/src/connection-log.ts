import { invoke } from '@tauri-apps/api/core';
import './connection-log.css';

type Location={id:string;country:string;city:string;host:string};
type ConnState={connected:boolean;state:string;public_ip?:string|null;exit_country?:string|null;latency_ms?:number|null};

const knownEndpoints:Record<string,string[]>={
  'tr-ist.prod.surfshark.com':['45.136.155.53','45.136.155.55','45.136.155.58','45.136.155.51'],
  'ee-tll.prod.surfshark.com':['185.174.159.123','185.174.159.107','185.174.159.109','185.174.159.194']
};

let lines:string[]=[];
let panel:HTMLElement|null=null;
let body:HTMLElement|null=null;
let toggle:HTMLButtonElement|null=null;
let monitoring=false;
let lastPhase='';

const stamp=()=>new Date().toLocaleTimeString([],{hour12:false});
function redact(v:string){return v.replace(/SERVICE_(?:USER|PASS)=[^\s]+/gi,'SERVICE_CREDENTIAL=[redacted]').replace(/secret\s*=\s*"[^"]+"/gi,'secret = [redacted]');}
function add(text:string){for(const line of redact(text).split('\n'))lines.push(`[${stamp()}] ${line}`);if(lines.length>600)lines=lines.slice(-600);render();}
function render(){if(body)body.textContent=lines.join('\n')||'No connection attempt captured yet.';}
function currentLocation(list:Location[]){const id=localStorage.getItem('milmit-selected-location');return list.find(x=>x.id===id)||list.find(x=>x.id==='ee-tll')||list[0];}
async function helper(action:string,args:string[]=[]){try{return await invoke<string>('helper_action',{action,args});}catch(e){return String(e);}}
async function snapshot(loc:Location,stage:string){add(`--- ${stage} ---`);try{const s=await invoke<ConnState>('connection_state');add(`state=${s.state} connected=${s.connected} exit=${s.exit_country||'—'} public_ip=${s.public_ip||'—'}`)}catch(e){add(`connection_state error: ${String(e)}`)}
 const route=await helper('route-explain',[loc.host]);add(`route-explain:\n${route}`);
}
async function collectAfter(loc:Location){await snapshot(loc,'POST-ATTEMPT SNAPSHOT');const health=await helper('health');add(`health:\n${health}`);const live=await helper('full-live-test');add(`live verification:\n${live}`);add('--- END ATTEMPT ---');}
async function beginAttempt(){if(monitoring)return;monitoring=true;lines=[];render();let locs:Location[]=[];try{locs=await invoke<Location[]>('list_locations')}catch(e){add(`Could not read location catalog: ${String(e)}`);monitoring=false;return}const loc=currentLocation(locs);if(!loc){monitoring=false;return}
 add('MilMit Secure Connection Log');add(`location=${loc.country} · ${loc.city}`);add(`identity=${loc.host}`);const candidates=knownEndpoints[loc.host];add(`bundled_candidates=${candidates?.join(', ')||'catalog-managed / see backend output'}`);
 try{const ping=await invoke<string>('ping_report',{kind:'location',host:loc.host});add(`preflight ping:\n${ping}`)}catch(e){add(`preflight ping failed: ${String(e)}`)}
 await snapshot(loc,'PRE-CONNECT SNAPSHOT');
 const started=Date.now();lastPhase='';const timer=window.setInterval(async()=>{const phase=(document.querySelector('.hero-area h2')?.textContent||'').trim();if(phase&&phase!==lastPhase){lastPhase=phase;add(`ui_state=${phase}`)}const busy=phase==='CONNECTING'||phase==='DISCONNECTING';if(!busy&&Date.now()-started>1200){window.clearInterval(timer);const toast=(document.querySelector('.toast')?.textContent||'').trim();if(toast)add(`ui_result=${toast}`);await collectAfter(loc);monitoring=false;}if(Date.now()-started>60000){window.clearInterval(timer);add('UI monitor timed out after 60s; collecting final diagnostics.');await collectAfter(loc);monitoring=false;}},700);
}
function build(){if(document.getElementById('milmit-connection-log-toggle'))return;const connect=document.querySelector<HTMLButtonElement>('.home-actions > .connect-btn, .home-actions > .disconnect-btn');if(!connect)return;
 toggle=document.createElement('button');toggle.id='milmit-connection-log-toggle';toggle.className='milmit-log-toggle';toggle.type='button';toggle.innerHTML='<span>☷</span><b>Log</b>';toggle.onclick=()=>panel?.classList.toggle('open');connect.insertAdjacentElement('afterend',toggle);
 panel=document.createElement('section');panel.id='milmit-connection-log-panel';panel.className='milmit-log-panel';panel.innerHTML='<div class="milmit-log-head"><div><b>Connection Log</b><small>Sanitized VPN diagnostics</small></div><div><button data-copy>Copy</button><button data-clear>Clear</button><button data-close>×</button></div></div><pre class="milmit-log-body">No connection attempt captured yet.</pre>';
 toggle.insertAdjacentElement('afterend',panel);body=panel.querySelector('.milmit-log-body');
 panel.querySelector<HTMLButtonElement>('[data-close]')!.onclick=()=>panel?.classList.remove('open');
 panel.querySelector<HTMLButtonElement>('[data-clear]')!.onclick=()=>{lines=[];render()};
 panel.querySelector<HTMLButtonElement>('[data-copy]')!.onclick=async()=>{try{await navigator.clipboard.writeText(lines.join('\n'));const b=panel?.querySelector<HTMLButtonElement>('[data-copy]');if(b){b.textContent='Copied';setTimeout(()=>b.textContent='Copy',1200)}}catch{}};
 connect.addEventListener('click',()=>{panel?.classList.add('open');setTimeout(()=>void beginAttempt(),50)},{capture:true});
 render();
}
const observer=new MutationObserver(()=>build());observer.observe(document.documentElement,{childList:true,subtree:true});build();
