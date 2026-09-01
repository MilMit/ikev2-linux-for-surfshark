import React, { useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { invoke } from '@tauri-apps/api/core';
import { Activity, ChevronLeft, ChevronRight, CirclePower, Gauge, ListPlus, Laptop, MapPin, Network, RefreshCw, Search, Server, Settings, Shield, Star, Wifi, Zap } from 'lucide-react';
import './styles.css';

type Page = 'home'|'locations'|'settings'|'vpn'|'split'|'splitApps'|'policies'|'devices'|'deviceList'|'guest'|'advanced'|'customLists'|'diagnostics';
type Location = { id:string; country:string; city:string; host:string; ping?:number|null };
type ConnState = { connected:boolean; state:string; public_ip?:string|null; exit_country?:string|null; latency_ms?:number|null };
type PingResult = { id:string; ping:number|null };
type CountryPingCache = { ts:number; values:Record<string,number|null> };
const FALLBACK:Location={id:'ee-tll',country:'Estonia',city:'Tallinn',host:'ee-tll.prod.surfshark.com',ping:null};
const COUNTRY_CACHE_KEY='milmit-country-pings-v2';
const LOCATION_CACHE_KEY='milmit-location-pings-v2';
const CACHE_MAX_AGE=15*60*1000;

function Row({title,subtitle,onClick,right}:{title:string;subtitle?:string;onClick?:()=>void;right?:React.ReactNode}){
  return <button className="settings-row" onClick={onClick}><span><b>{title}</b>{subtitle&&<small>{subtitle}</small>}</span>{right??<ChevronRight size={18}/>}</button>;
}
const pingLabel=(v?:number|null)=>typeof v==='number'?`${v} ms`:'—';
function flagFor(id:string){const cc=id.slice(0,2).toUpperCase();return /^[A-Z]{2}$/.test(cc)?String.fromCodePoint(...[...cc].map(c=>127397+c.charCodeAt(0))):'🌐';}
function readJson<T>(key:string,fallback:T):T{try{return JSON.parse(localStorage.getItem(key)||'') as T}catch{return fallback}}

function App(){
  const [page,setPage]=useState<Page>('home');
  const [locations,setLocations]=useState<Location[]>([FALLBACK]);
  const [selected,setSelected]=useState<Location>(FALLBACK);
  const [query,setQuery]=useState('');
  const [favorites,setFavorites]=useState<Set<string>>(()=>new Set(readJson<string[]>('milmit-favorites',[])));
  const [recent,setRecent]=useState<string[]>(()=>readJson<string[]>('milmit-recent-locations',[]));
  const cachedCountries=readJson<CountryPingCache>(COUNTRY_CACHE_KEY,{ts:0,values:{}});
  const [countryPings,setCountryPings]=useState<Record<string,number|null>>(cachedCountries.values||{});
  const [countryScanning,setCountryScanning]=useState(false);
  const [scanning,setScanning]=useState(false);
  const [scanProgress,setScanProgress]=useState('');
  const [busy,setBusy]=useState(false);
  const [phase,setPhase]=useState('');
  const [conn,setConn]=useState<ConnState>({connected:false,state:'DISCONNECTED'});
  const [toast,setToast]=useState('');
  const [diag,setDiag]=useState('');
  const [policyTarget,setPolicyTarget]=useState('');
  const [guestMinutes,setGuestMinutes]=useState('60');
  const [guestSsid,setGuestSsid]=useState('MilMit Guest');

  useEffect(()=>{void invoke<Location[]>('list_locations').then(list=>{
    if(!list.length)return;
    const savedPings=readJson<{ts:number;values:Record<string,number|null>}>(LOCATION_CACHE_KEY,{ts:0,values:{}});
    const sorted=[...list].sort((a,b)=>a.country.localeCompare(b.country)||a.city.localeCompare(b.city)).map(x=>({...x,ping:savedPings.values?.[x.id]??null}));
    setLocations(sorted);
    const saved=localStorage.getItem('milmit-selected-location'); setSelected(sorted.find(x=>x.id===saved)||sorted.find(x=>x.id==='ee-tll')||sorted[0]);
  }).catch(e=>setToast(`Could not load locations: ${String(e)}`));},[]);

  useEffect(()=>{const refresh=()=>void invoke<ConnState>('connection_state').then(setConn).catch(()=>{});refresh();const t=setInterval(refresh,2500);return()=>clearInterval(t);},[]);
  useEffect(()=>{if(!toast)return;const t=setTimeout(()=>setToast(''),4200);return()=>clearTimeout(t);},[toast]);

  const filtered=useMemo(()=>locations.filter(x=>`${x.country} ${x.city} ${x.host}`.toLowerCase().includes(query.toLowerCase())),[locations,query]);
  const grouped=useMemo(()=>{const m=new Map<string,Location[]>();for(const l of filtered){const a=m.get(l.country)||[];a.push(l);m.set(l.country,a)}return[...m.entries()]},[filtered]);
  const allGrouped=useMemo(()=>{const m=new Map<string,Location[]>();for(const l of locations){const a=m.get(l.country)||[];a.push(l);m.set(l.country,a)}return[...m.entries()]},[locations]);
  const recentLocations=useMemo(()=>recent.map(id=>locations.find(x=>x.id===id)).filter(Boolean) as Location[],[recent,locations]);
  const favoriteLocations=useMemo(()=>locations.filter(x=>favorites.has(x.id)),[favorites,locations]);

  function saveLocationPings(next:Location[]){const values:Record<string,number|null>={};for(const l of next)if(typeof l.ping==='number')values[l.id]=l.ping;localStorage.setItem(LOCATION_CACHE_KEY,JSON.stringify({ts:Date.now(),values}))}
  function applyPings(results:PingResult[]){setLocations(prev=>{const map=new Map(results.map(x=>[x.id,x.ping]));const next=prev.map(l=>map.has(l.id)?{...l,ping:map.get(l.id)??null}:l);saveLocationPings(next);return next})}

  async function batchPing(list:Location[]):Promise<PingResult[]>{
    if(!list.length)return[];
    return invoke<PingResult[]>('ping_locations_batch',{items:list.map(x=>({id:x.id,host:x.host}))});
  }

  async function scanCountryHeaders(force=false){
    if(countryScanning||locations.length<2)return;
    const cache=readJson<CountryPingCache>(COUNTRY_CACHE_KEY,{ts:0,values:{}});
    if(!force&&Date.now()-cache.ts<CACHE_MAX_AGE&&Object.keys(cache.values||{}).length>10){setCountryPings(cache.values);return;}
    setCountryScanning(true);
    try{
      // One representative endpoint per country. This gives the country row a
      // useful latency immediately without expanding every city or spawning
      // 123 individual IPC calls.
      const reps=allGrouped.map(([,locs])=>locs.find(x=>typeof x.ping==='number')||locs[0]);
      const results=await batchPing(reps);
      const byId=new Map(results.map(x=>[x.id,x.ping]));
      const next:Record<string,number|null>={};
      for(const [country,locs] of allGrouped){const rep=locs.find(x=>typeof x.ping==='number')||locs[0];next[country]=byId.get(rep.id)??rep.ping??null;}
      setCountryPings(next); localStorage.setItem(COUNTRY_CACHE_KEY,JSON.stringify({ts:Date.now(),values:next}));
      applyPings(results);
    }catch{/* keep cached country pings */}finally{setCountryScanning(false)}
  }

  useEffect(()=>{if(page==='locations'&&locations.length>1)void scanCountryHeaders(false)},[page,locations.length]);

  async function scanList(list:Location[],label='Scanning latency'){
    if(!list.length||scanning)return; setScanning(true); let done=0;
    try{
      for(let i=0;i<list.length;i+=24){const chunk=list.slice(i,i+24);const res=await batchPing(chunk);applyPings(res);done+=chunk.length;setScanProgress(`${label} · ${done}/${list.length}`);await new Promise(r=>setTimeout(r,0));}
      // Country rows should immediately reflect the best measured city.
      setLocations(current=>{const nextCountry:Record<string,number|null>={...countryPings};for(const [country,locs] of allGrouped){const vals=locs.map(l=>current.find(x=>x.id===l.id)?.ping).filter((v):v is number=>typeof v==='number');if(vals.length)nextCountry[country]=Math.min(...vals)}setCountryPings(nextCountry);localStorage.setItem(COUNTRY_CACHE_KEY,JSON.stringify({ts:Date.now(),values:nextCountry}));return current});
    }finally{setScanning(false);setScanProgress('')}
  }
  async function scanAll(selectFastest=false){await scanList(locations,selectFastest?'Finding fastest':'Scanning all');if(selectFastest){setLocations(current=>{const best=[...current].filter(x=>typeof x.ping==='number').sort((a,b)=>(a.ping??99999)-(b.ping??99999))[0];if(best){chooseLocation(best,false);setToast(`Fastest: ${best.country} · ${best.city} · ${best.ping} ms`)}return current})}}
  function scanCountry(locs:Location[]){const needed=locs.filter(x=>typeof x.ping!=='number');if(needed.length&&!scanning)void scanList(needed,'Scanning country')}
  function countryPing(country:string,locs:Location[]){const measured=locs.map(x=>x.ping).filter((v):v is number=>typeof v==='number');return measured.length?Math.min(...measured):countryPings[country]}

  function toggleFavorite(id:string){setFavorites(prev=>{const n=new Set(prev);n.has(id)?n.delete(id):n.add(id);localStorage.setItem('milmit-favorites',JSON.stringify([...n]));return n})}
  function chooseLocation(loc:Location,goHome=true){setSelected(loc);localStorage.setItem('milmit-selected-location',loc.id);setRecent(prev=>{const n=[loc.id,...prev.filter(x=>x!==loc.id)].slice(0,8);localStorage.setItem('milmit-recent-locations',JSON.stringify(n));return n});if(goHome)setPage('home')}

  async function helper(name:string,args:string[]=[],show=false){setBusy(true);try{const r=await invoke<string>('helper_action',{action:name,args});if(show)setDiag(r||'Completed successfully.');setToast(`${name.replaceAll('-',' ')} completed`);return r}catch(e){const t=String(e);if(show)setDiag(t);setToast(t.length>120?`${t.slice(0,120)}…`:t);throw e}finally{setBusy(false)}}
  async function toggleConnection(){try{if(conn.connected){setPhase('DISCONNECTING');await helper('disconnect');}else{setPhase('CONNECTING');const r=await invoke<string>('connect_location',{id:selected.id});setToast(r.includes(`IDENTITY=${selected.host}`)?`Connected to ${selected.country} · ${selected.city}`:'Connected and verified');}setTimeout(()=>void invoke<ConnState>('connection_state').then(setConn),500)}catch(e){setToast(String(e).slice(0,170))}finally{setPhase('')}}
  async function runPing(kind:'internet'|'vpn'|'location'){setBusy(true);setDiag('Running 8-packet ping…');try{setDiag(await invoke<string>('ping_report',{kind,host:selected.host}));setPage('diagnostics')}catch(e){setDiag(String(e));setPage('diagnostics')}finally{setBusy(false)}}

  const header=(title:string,back:Page)=><header className="topbar"><button className="icon-btn" onClick={()=>setPage(back)}><ChevronLeft/></button><h1>{title}</h1><span/></header>;
  const toastView=toast?<div className="toast" onClick={()=>setToast('')}>{toast}</div>:null;
  const locRow=(loc:Location,prefix='')=><button key={`${prefix}${loc.id}`} className={`location-row ${selected.id===loc.id?'selected-location':''}`} onClick={()=>chooseLocation(loc)}><span className="city-rail"/><span className="loc-main"><b>{loc.city}</b><small>{loc.host}</small></span><span className={`latency ${typeof loc.ping==='number'?'latency-live':''}`}>{pingLabel(loc.ping)}</span><span className="star-hit" onClick={e=>{e.stopPropagation();toggleFavorite(loc.id)}}><Star size={17} fill={favorites.has(loc.id)?'currentColor':'none'}/></span></button>;

  if(page==='locations')return <main className="app-shell">{header('Select location','home')}{toastView}<section className="page-pad locations-page">
    <div className="search"><Search size={18}/><input value={query} onChange={e=>setQuery(e.target.value)} placeholder="Search country, city or hostname"/></div>
    <div className="location-toolbar"><button onClick={()=>void scanAll(true)} disabled={scanning}><Zap size={15}/>Fastest</button><button onClick={()=>void scanAll(false)} disabled={scanning}><RefreshCw size={15} className={scanning?'spin':''}/>Scan all</button><button className="quiet-scan" onClick={()=>void scanCountryHeaders(true)} disabled={countryScanning}><RefreshCw size={14} className={countryScanning?'spin':''}/>{countryScanning?'Countries…':'Refresh countries'}</button><span>{scanProgress||`${locations.length} locations`}</span></div>
    {!query&&favoriteLocations.length>0&&<section className="quick-section"><div className="section-title">FAVORITES</div><div className="quick-list">{favoriteLocations.slice(0,6).map(l=><button key={`f-${l.id}`} className="quick-location" onClick={()=>chooseLocation(l)}><span className="flag">{flagFor(l.id)}</span><span><b>{l.country}</b><small>{l.city}</small></span><em>{pingLabel(l.ping)}</em></button>)}</div></section>}
    {!query&&recentLocations.length>0&&<section className="quick-section"><div className="section-title">RECENT</div><div className="quick-list">{recentLocations.slice(0,5).map(l=><button key={`r-${l.id}`} className="quick-location" onClick={()=>chooseLocation(l)}><span className="flag">{flagFor(l.id)}</span><span><b>{l.country}</b><small>{l.city}</small></span><em>{pingLabel(l.ping)}</em></button>)}</div></section>}
    <div className="section-title">ALL LOCATIONS</div>
    <div className="country-list">{grouped.map(([country,locs])=><details className="country-group" key={country} open={query.length>0} onToggle={e=>{if((e.currentTarget as HTMLDetailsElement).open)scanCountry(locs)}}><summary><ChevronRight className="country-chevron" size={18}/><span className="flag">{flagFor(locs[0].id)}</span><b>{country}</b><span className={`country-latency ${typeof countryPing(country,locs)==='number'?'latency-live':''}`}>{pingLabel(countryPing(country,locs))}</span><span className="country-count">{locs.length}</span></summary><div className="location-list">{locs.map(l=>locRow(l))}</div></details>)}</div>
  </section></main>;

  if(page==='settings')return <main className="app-shell">{header('Settings','home')}{toastView}<section className="page-pad stack-list"><Row title="VPN settings" subtitle="Kill switch, DNS, transport and Iran bypass" onClick={()=>setPage('vpn')}/><Row title="Split tunneling" subtitle="Apps, domains, IPs and Iran direct routing" onClick={()=>setPage('split')}/><Row title="Hotspot & devices" subtitle="Per-device VPN, Direct, Block, quota and guest" onClick={()=>setPage('devices')}/><Row title="Advanced" subtitle="Diagnostics, location lists and recovery" onClick={()=>setPage('advanced')}/></section></main>;
  if(page==='vpn')return <main className="app-shell">{header('VPN settings','settings')}{toastView}<section className="page-pad stack-list"><div className="info-card"><Shield size={20}/><span><b>VPN protection</b><small>Connect is bound to the selected location and verified against the active IKE server identity.</small></span></div><Row title="Protection health" subtitle="Check tunnel, routing and data path" onClick={()=>{setPage('diagnostics');void helper('health',[],true)}} right={<Activity size={18}/>}/><Row title="Update Iran rules" subtitle="Refresh validated Iran CIDR rules" onClick={()=>void helper('rules-update')} right={<RefreshCw size={18}/>}/><Row title="Repair routing safely" subtitle="Apply protection with rollback verification" onClick={()=>void helper('apply-safe')} right={<Network size={18}/>}/><Row title="Emergency network recovery" subtitle="Remove MilMit routing and recover network" onClick={()=>void helper('emergency-stop')} right={<Shield size={18}/>}/></section></main>;
  if(page==='split')return <main className="app-shell">{header('Split tunneling','settings')}{toastView}<section className="page-pad stack-list"><div className="info-card"><Shield size={20}/><span><b>Split tunneling</b><small>Domain/IP policies are live. Per-app backend is still being implemented.</small></span></div><Row title="Applications" subtitle="Linux application bypass/force list" onClick={()=>setPage('splitApps')} right={<Laptop size={18}/>}/><Row title="Domain / IP policies" subtitle="Direct, VPN or Block rules" onClick={()=>setPage('policies')} right={<Network size={18}/>}/><Row title="Route explain" subtitle="Explain why a destination is Direct/VPN/Blocked" onClick={()=>setPage('policies')}/></section></main>;
  if(page==='splitApps')return <main className="app-shell">{header('Applications','split')}{toastView}<section className="page-pad stack-list"><div className="info-card"><Laptop size={20}/><span><b>App-based split tunneling</b><small>Backend cgroup/mark routing is not enabled yet; no fake switches are shown.</small></span></div><Row title="Application discovery" subtitle="Backend implementation required" right={<span className="status-chip">NEXT</span>}/></section></main>;
  if(page==='policies')return <main className="app-shell">{header('Domain / IP policies','split')}{toastView}<section className="page-pad stack-list"><div className="field-card"><label>Domain, IP or CIDR</label><input value={policyTarget} onChange={e=>setPolicyTarget(e.target.value)} placeholder="example.com or 1.2.3.0/24"/></div><div className="action-grid"><button onClick={()=>policyTarget&&void helper('policy-add',[policyTarget,'direct','both'])}>Bypass VPN</button><button onClick={()=>policyTarget&&void helper('policy-add',[policyTarget,'vpn','both'])}>Force VPN</button><button onClick={()=>policyTarget&&void helper('policy-add',[policyTarget,'block','both'])}>Block</button></div><button className="secondary-btn" onClick={()=>policyTarget&&void helper('route-explain',[policyTarget],true).then(()=>setPage('diagnostics'))}>Explain route</button><button className="secondary-btn" onClick={()=>policyTarget&&void helper('policy-remove',[policyTarget,'both'])}>Remove policy</button></section></main>;
  if(page==='devices')return <main className="app-shell">{header('Hotspot & devices','settings')}{toastView}<section className="page-pad stack-list"><div className="info-card"><Wifi size={20}/><span><b>Protected hotspot</b><small>Manage phones and clients individually.</small></span></div><Row title="Connected devices" subtitle="VPN / Direct / Block / Pause" onClick={()=>{setPage('deviceList');void helper('router-status',[],true)}}/><Row title="Guest hotspot" subtitle="Temporary SSID with auto-expiry" onClick={()=>setPage('guest')}/><Row title="Repair hotspot routing" subtitle="Reapply hotspot firewall and routing" onClick={()=>void helper('hotspot-repair')}/></section></main>;
  if(page==='deviceList')return <main className="app-shell">{header('Connected devices','devices')}{toastView}<section className="page-pad"><button className="secondary-btn" onClick={()=>void helper('router-status',[],true)}>Refresh device/router state</button><pre className="diagnostic-box">{diag||'No router status loaded yet.'}</pre></section></main>;
  if(page==='guest')return <main className="app-shell">{header('Guest hotspot','devices')}{toastView}<section className="page-pad stack-list"><div className="field-card"><label>SSID</label><input value={guestSsid} onChange={e=>setGuestSsid(e.target.value)}/></div><div className="field-card"><label>Duration (minutes)</label><input value={guestMinutes} onChange={e=>setGuestMinutes(e.target.value)} inputMode="numeric"/></div><button className="connect-btn" onClick={()=>void helper('guest-start',[guestMinutes||'60',guestSsid||'MilMit Guest'])}>Start Guest Hotspot</button><button className="disconnect-btn" onClick={()=>void helper('guest-stop')}>Stop Guest Hotspot</button></section></main>;
  if(page==='advanced')return <main className="app-shell">{header('Advanced settings','settings')}{toastView}<section className="page-pad stack-list"><Row title="Custom location lists" subtitle="Create reusable server groups" onClick={()=>setPage('customLists')} right={<ListPlus size={18}/>}/><Row title="Diagnostics" subtitle="Health, latency, routes, DNS and support bundle" onClick={()=>setPage('diagnostics')} right={<Activity size={18}/>}/><Row title="Candidate destinations" subtitle="Review recent routing candidates" onClick={()=>{setPage('diagnostics');void helper('candidates',[],true)}} right={<Server size={18}/>}/><Row title="Rules status" subtitle="Show current Iran rules snapshot" onClick={()=>{setPage('diagnostics');void helper('rules-status',[],true)}}/></section></main>;
  if(page==='customLists')return <main className="app-shell">{header('Custom location lists','advanced')}{toastView}<section className="page-pad stack-list"><div className="info-card"><ListPlus size={20}/><span><b>Custom lists</b><small>Favorites are persistent. Named custom groups are still pending.</small></span></div><Row title="Favorites" subtitle={`${favorites.size} saved locations`} right={<Star size={18}/>}/><button className="secondary-btn" disabled>Create new list — backend next</button></section></main>;
  if(page==='diagnostics')return <main className="app-shell">{header('Diagnostics','advanced')}{toastView}<section className="page-pad stack-list"><div className="section-title">PING & LATENCY</div><div className="action-grid"><button onClick={()=>void runPing('internet')}>Ping Internet</button><button onClick={()=>void runPing('vpn')}>Ping VPN</button><button onClick={()=>void runPing('location')}>Ping Location</button></div><div className="section-title">NETWORK TESTS</div><div className="action-grid"><button onClick={()=>void helper('health',[],true)}>Health</button><button onClick={()=>void helper('speed-test',[],true)}>Speed</button><button onClick={()=>void helper('dns-test',[],true)}>DNS</button></div><div className="action-grid"><button onClick={()=>void helper('mtu-test',[],true)}>MTU/MSS</button><button onClick={()=>void helper('full-live-test',[],true)}>Live test</button><button onClick={()=>void helper('support-bundle',[],true)}>Support</button></div><pre className="diagnostic-box">{busy?'Running…':(diag||'Ping reports include packet loss, min/avg/max RTT and jitter/mdev.')}</pre></section></main>;

  const stateText=phase||conn.state||(conn.connected?'CONNECTED':'DISCONNECTED');
  return <main className={`app-shell ${conn.connected?'connected':''}`}><header className="topbar"><div className="brand"><span className="brand-mark"><Shield size={17}/></span><b>MilMit Secure</b></div><button className="icon-btn" onClick={()=>setPage('settings')}><Settings/></button></header>{toastView}<section className="hero-area"><div className={`status-orb ${phase?'working':''}`}><Shield size={46}/></div><h2>{stateText}</h2><p>{conn.connected?'Your traffic is protected':'Connect to protect your traffic'}</p></section><section className="home-actions"><button className="location-card" onClick={()=>setPage('locations')}><span className="flag big-flag">{flagFor(selected.id)}</span><span><b>{selected.country}</b><small>{selected.city}</small></span><span className="latency">{pingLabel(locations.find(x=>x.id===selected.id)?.ping)}</span><ChevronRight/></button><button disabled={busy||!!phase} className={conn.connected?'disconnect-btn':'connect-btn'} onClick={()=>void toggleConnection()}><CirclePower size={20}/>{conn.connected?'Disconnect':'Secure my connection'}</button><div className="metrics"><div><Gauge/><b>{conn.latency_ms?`${conn.latency_ms} ms`:pingLabel(locations.find(x=>x.id===selected.id)?.ping)}</b><small>Latency</small></div><div><Shield/><b>{conn.public_ip||'—'}</b><small>Public IP</small></div><div><MapPin/><b>{conn.exit_country||'—'}</b><small>Exit</small></div></div></section></main>;
}
createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>);
