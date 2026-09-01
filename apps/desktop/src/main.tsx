import React, { useEffect, useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { invoke } from '@tauri-apps/api/core';
import { ChevronLeft, ChevronRight, CirclePower, Gauge, LockKeyhole, MapPin, Search, Settings, Shield, Star, Wifi, Activity, ListPlus, Laptop, Network, Server, RefreshCw } from 'lucide-react';
import './styles.css';

type Page = 'home' | 'locations' | 'settings' | 'vpn' | 'split' | 'splitApps' | 'policies' | 'devices' | 'deviceList' | 'guest' | 'advanced' | 'customLists' | 'diagnostics';
type Location = { id: string; country: string; city: string; host: string; ping?: number | null };
const FALLBACK_LOCATION: Location = { id: 'ee-tll', country: 'Estonia', city: 'Tallinn', host: 'ee-tll.prod.surfshark.com', ping: null };

function Row({ title, subtitle, onClick, right }: { title: string; subtitle?: string; onClick?: () => void; right?: React.ReactNode }) {
  return <button className="settings-row" onClick={onClick}><span><b>{title}</b>{subtitle && <small>{subtitle}</small>}</span>{right ?? <ChevronRight size={18}/>}</button>;
}

function pingLabel(value?: number | null) {
  return typeof value === 'number' ? `${value} ms` : '—';
}

function App() {
  const [page, setPage] = useState<Page>('home');
  const [connected, setConnected] = useState(false);
  const [busy, setBusy] = useState(false);
  const [locations, setLocations] = useState<Location[]>([FALLBACK_LOCATION]);
  const [selected, setSelected] = useState<Location>(FALLBACK_LOCATION);
  const [query, setQuery] = useState('');
  const [toast, setToast] = useState('');
  const [diag, setDiag] = useState('');
  const [policyTarget, setPolicyTarget] = useState('');
  const [guestMinutes, setGuestMinutes] = useState('60');
  const [guestSsid, setGuestSsid] = useState('MilMit Guest');
  const [favorites, setFavorites] = useState<Set<string>>(() => new Set(JSON.parse(localStorage.getItem('milmit-favorites') || '[]')));
  const [scanning, setScanning] = useState(false);

  useEffect(() => {
    void invoke<Location[]>('list_locations').then(list => {
      if (!list.length) return;
      const sorted = [...list].sort((a,b) => a.country.localeCompare(b.country) || a.city.localeCompare(b.city));
      setLocations(sorted);
      const saved = localStorage.getItem('milmit-selected-location');
      const next = sorted.find(x => x.id === saved) || sorted.find(x => x.id === 'ee-tll') || sorted[0];
      setSelected(next);
    }).catch(e => setToast(`Could not load location catalog: ${String(e)}`));
  }, []);

  useEffect(() => {
    if (page !== 'locations' || scanning || locations.length < 2) return;
    setScanning(true);
    let cancelled = false;
    void (async () => {
      const copy = [...locations];
      for (let i = 0; i < copy.length && !cancelled; i += 8) {
        const chunk = copy.slice(i, i + 8);
        const results = await Promise.all(chunk.map(async loc => {
          try { return [loc.id, await invoke<number | null>('ping_location', { host: loc.host })] as const; }
          catch { return [loc.id, null] as const; }
        }));
        if (cancelled) break;
        setLocations(prev => prev.map(loc => {
          const hit = results.find(([id]) => id === loc.id);
          return hit ? { ...loc, ping: hit[1] } : loc;
        }));
      }
      if (!cancelled) setScanning(false);
    })();
    return () => { cancelled = true; setScanning(false); };
  }, [page]);

  const filtered = useMemo(() => locations.filter(x => `${x.country} ${x.city} ${x.host}`.toLowerCase().includes(query.toLowerCase())), [locations, query]);
  const grouped = useMemo(() => {
    const map = new Map<string, Location[]>();
    for (const loc of filtered) {
      const arr = map.get(loc.country) || [];
      arr.push(loc);
      map.set(loc.country, arr);
    }
    return [...map.entries()];
  }, [filtered]);

  function toggleFavorite(id: string) {
    setFavorites(prev => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      localStorage.setItem('milmit-favorites', JSON.stringify([...next]));
      return next;
    });
  }

  function chooseLocation(loc: Location) {
    setSelected(loc);
    localStorage.setItem('milmit-selected-location', loc.id);
    setPage('home');
  }

  async function helper(name: string, args: string[] = [], showResult = false) {
    setBusy(true);
    try {
      const result = await invoke<string>('helper_action', { action: name, args });
      if (showResult) setDiag(result || 'Completed successfully.');
      setToast(`${name.replaceAll('-', ' ')} completed`);
      return result;
    } catch (e) {
      const text = String(e);
      if (showResult) setDiag(text);
      setToast(text.length > 110 ? `${text.slice(0, 110)}…` : text);
      throw e;
    } finally { setBusy(false); }
  }

  async function toggleConnection() {
    try {
      if (connected) {
        await helper('disconnect');
        setConnected(false);
      } else {
        const result = await helper('quick-connect');
        setConnected(result.toLowerCase().includes('ok') || result.toLowerCase().includes('established') || result.toLowerCase().includes('data-path test'));
      }
    } catch { /* toast already shown */ }
  }

  const header = (title: string, back: Page) => <header className="topbar"><button className="icon-btn" onClick={() => setPage(back)}><ChevronLeft/></button><h1>{title}</h1><span/></header>;
  const toastView = toast ? <div className="toast" onClick={()=>setToast('')}>{toast}</div> : null;

  if (page === 'locations') return <main className="app-shell">{header('Select location','home')}{toastView}<section className="page-pad">
    <div className="search"><Search size={17}/><input value={query} onChange={e=>setQuery(e.target.value)} placeholder="Search country, city or hostname"/></div>
    <div className="section-title">{scanning ? 'SCANNING LATENCY…' : `${locations.length} LOCATIONS`}</div>
    {[...favorites].length > 0 && <><div className="section-title">FAVORITES</div><div className="location-list">{locations.filter(x=>favorites.has(x.id)).map(loc => <button key={`fav-${loc.id}`} className="location-row" onClick={()=>chooseLocation(loc)}><span className="flag-dot"/><span className="loc-main"><b>{loc.country}</b><small>{loc.city}</small></span><span className="ping">{pingLabel(loc.ping)}</span><Star size={16} fill="currentColor" onClick={e=>{e.stopPropagation();toggleFavorite(loc.id)}}/></button>)}</div></>}
    <div className="section-title">ALL LOCATIONS</div>
    <div className="country-list">{grouped.map(([country, locs]) => <details className="country-group" key={country} open={query.length > 0}><summary><span>{country}</span><small>{locs.length}</small></summary><div className="location-list">{locs.map(loc => <button key={loc.id} className="location-row" onClick={()=>chooseLocation(loc)}><span className="flag-dot"/><span className="loc-main"><b>{loc.city}</b><small>{loc.host}</small></span><span className="ping">{pingLabel(loc.ping)}</span><Star size={16} fill={favorites.has(loc.id) ? 'currentColor' : 'none'} onClick={e=>{e.stopPropagation();toggleFavorite(loc.id)}}/></button>)}</div></details>)}</div>
  </section></main>;

  if (page === 'settings') return <main className="app-shell">{header('Settings','home')}{toastView}<section className="page-pad stack-list">
    <Row title="VPN settings" subtitle="Kill switch, DNS, transport and Iran bypass" onClick={()=>setPage('vpn')}/>
    <Row title="Split tunneling" subtitle="Apps, domains, IPs and Iran direct routing" onClick={()=>setPage('split')}/>
    <Row title="Hotspot & devices" subtitle="Per-device VPN, Direct, Block, quota and guest" onClick={()=>setPage('devices')}/>
    <Row title="Advanced" subtitle="Auto-connect, lockdown, diagnostics and recovery" onClick={()=>setPage('advanced')}/>
  </section></main>;

  if (page === 'vpn') return <main className="app-shell">{header('VPN settings','settings')}{toastView}<section className="page-pad stack-list">
    <div className="info-card"><Shield size={20}/><span><b>VPN protection</b><small>Actions below call the installed privileged helper, not demo buttons.</small></span></div>
    <Row title="Protection health" subtitle="Check tunnel, routing and data path" onClick={()=>{setPage('diagnostics'); void helper('health',[],true)}} right={<Activity size={18}/>}/>
    <Row title="Update Iran rules" subtitle="Refresh validated Iran CIDR rules" onClick={()=>void helper('rules-update')} right={<RefreshCw size={18}/>}/>
    <Row title="Repair routing safely" subtitle="Apply protection with rollback verification" onClick={()=>void helper('apply-safe')} right={<Network size={18}/>}/>
    <Row title="Emergency network recovery" subtitle="Remove MilMit routing and recover network" onClick={()=>void helper('emergency-stop')} right={<Shield size={18}/>}/>
  </section></main>;

  if (page === 'split') return <main className="app-shell">{header('Split tunneling','settings')}{toastView}<section className="page-pad stack-list">
    <div className="info-card"><Shield size={20}/><span><b>Split tunneling</b><small>App UI is being prepared; domain/IP policies are live now.</small></span></div>
    <Row title="Applications" subtitle="Linux application bypass/force list" onClick={()=>setPage('splitApps')} right={<Laptop size={18}/>}/>
    <Row title="Domain / IP policies" subtitle="Direct, VPN or Block rules" onClick={()=>setPage('policies')} right={<Network size={18}/>}/>
    <Row title="Route explain" subtitle="Explain why a destination is Direct/VPN/Blocked" onClick={()=>setPage('policies')}/>
  </section></main>;

  if (page === 'splitApps') return <main className="app-shell">{header('Applications','split')}{toastView}<section className="page-pad stack-list">
    <div className="info-card"><Laptop size={20}/><span><b>App-based split tunneling</b><small>The navigation is now real. Backend app-exclusion support is the next implementation step; fake toggles are intentionally not shown.</small></span></div>
    <Row title="Application discovery" subtitle="Installed desktop apps will appear here after backend cgroup/mark routing is added" right={<span className="status-chip">NEXT</span>}/>
  </section></main>;

  if (page === 'policies') return <main className="app-shell">{header('Domain / IP policies','split')}{toastView}<section className="page-pad stack-list">
    <div className="field-card"><label>Domain, IP or CIDR</label><input value={policyTarget} onChange={e=>setPolicyTarget(e.target.value)} placeholder="example.com or 1.2.3.0/24"/></div>
    <div className="action-grid"><button onClick={()=>policyTarget && void helper('policy-add',[policyTarget,'direct','both'])}>Bypass VPN</button><button onClick={()=>policyTarget && void helper('policy-add',[policyTarget,'vpn','both'])}>Force VPN</button><button onClick={()=>policyTarget && void helper('policy-add',[policyTarget,'block','both'])}>Block</button></div>
    <button className="secondary-btn" onClick={()=>policyTarget && void helper('route-explain',[policyTarget],true).then(()=>setPage('diagnostics'))}>Explain route</button>
    <button className="secondary-btn" onClick={()=>policyTarget && void helper('policy-remove',[policyTarget,'both'])}>Remove policy</button>
  </section></main>;

  if (page === 'devices') return <main className="app-shell">{header('Hotspot & devices','settings')}{toastView}<section className="page-pad stack-list">
    <div className="info-card"><Wifi size={20}/><span><b>Protected hotspot</b><small>Manage phones and clients individually.</small></span></div>
    <Row title="Connected devices" subtitle="VPN / Direct / Block / Pause" onClick={()=>{setPage('deviceList');void helper('router-status',[],true)}}/>
    <Row title="Guest hotspot" subtitle="Temporary SSID with auto-expiry" onClick={()=>setPage('guest')}/>
    <Row title="Repair hotspot routing" subtitle="Reapply hotspot firewall and routing" onClick={()=>void helper('hotspot-repair')}/>
  </section></main>;

  if (page === 'deviceList') return <main className="app-shell">{header('Connected devices','devices')}{toastView}<section className="page-pad">
    <button className="secondary-btn" onClick={()=>void helper('router-status',[],true)}>Refresh device/router state</button>
    <pre className="diagnostic-box">{diag || 'No router status loaded yet.'}</pre>
  </section></main>;

  if (page === 'guest') return <main className="app-shell">{header('Guest hotspot','devices')}{toastView}<section className="page-pad stack-list">
    <div className="field-card"><label>SSID</label><input value={guestSsid} onChange={e=>setGuestSsid(e.target.value)}/></div>
    <div className="field-card"><label>Duration (minutes)</label><input value={guestMinutes} onChange={e=>setGuestMinutes(e.target.value)} inputMode="numeric"/></div>
    <button className="connect-btn" onClick={()=>void helper('guest-start',[guestMinutes || '60',guestSsid || 'MilMit Guest'])}>Start Guest Hotspot</button>
    <button className="disconnect-btn" onClick={()=>void helper('guest-stop')}>Stop Guest Hotspot</button>
    <button className="secondary-btn" onClick={()=>void helper('guest-status',[],true).then(()=>setPage('diagnostics'))}>Guest status</button>
  </section></main>;

  if (page === 'advanced') return <main className="app-shell">{header('Advanced settings','settings')}{toastView}<section className="page-pad stack-list">
    <Row title="Custom location lists" subtitle="Create reusable server groups" onClick={()=>setPage('customLists')} right={<ListPlus size={18}/>}/>
    <Row title="Diagnostics" subtitle="Health, latency, routes, DNS and support bundle" onClick={()=>setPage('diagnostics')} right={<Activity size={18}/>}/>
    <Row title="Candidate destinations" subtitle="Review recent routing candidates" onClick={()=>{setPage('diagnostics');void helper('candidates',[],true)}} right={<Server size={18}/>}/>
    <Row title="Rules status" subtitle="Show current Iran rules snapshot" onClick={()=>{setPage('diagnostics');void helper('rules-status',[],true)}}/>
  </section></main>;

  if (page === 'customLists') return <main className="app-shell">{header('Custom location lists','advanced')}{toastView}<section className="page-pad stack-list">
    <div className="info-card"><ListPlus size={20}/><span><b>Custom lists</b><small>Favorites now use the full real location catalog.</small></span></div>
    <Row title="Favorites" subtitle={`${favorites.size} saved locations`} right={<Star size={18}/>}/>
    <button className="secondary-btn" disabled>Create new list — backend next</button>
  </section></main>;

  if (page === 'diagnostics') return <main className="app-shell">{header('Diagnostics','advanced')}{toastView}<section className="page-pad stack-list">
    <div className="action-grid"><button onClick={()=>void helper('health',[],true)}>Health</button><button onClick={()=>void helper('speed-test',[],true)}>Speed</button><button onClick={()=>void helper('dns-test',[],true)}>DNS</button></div>
    <div className="action-grid"><button onClick={()=>void helper('mtu-test',[],true)}>MTU/MSS</button><button onClick={()=>void helper('full-live-test',[],true)}>Live test</button><button onClick={()=>void helper('support-bundle',[],true)}>Support</button></div>
    <pre className="diagnostic-box">{busy ? 'Running…' : (diag || 'Choose a diagnostic action.')}</pre>
  </section></main>;

  return <main className={`app-shell ${connected ? 'connected' : ''}`}>
    <header className="topbar"><div className="brand"><Shield size={20}/><b>MilMit Secure</b></div><button className="icon-btn" onClick={()=>setPage('settings')}><Settings/></button></header>{toastView}
    <section className="hero-area"><div className="status-orb"><LockKeyhole size={44}/></div><h2>{busy ? 'WORKING…' : connected ? 'SECURE CONNECTION' : 'UNSECURED CONNECTION'}</h2><p>{connected ? 'Your traffic is protected' : 'Connect to protect your traffic'}</p></section>
    <section className="home-actions">
      <button className="location-card" onClick={()=>setPage('locations')}><MapPin/><span><b>{selected.country}</b><small>{selected.city}</small></span><span className="ping">{pingLabel(locations.find(x=>x.id===selected.id)?.ping)}</span><ChevronRight/></button>
      <button disabled={busy} className={connected ? 'disconnect-btn' : 'connect-btn'} onClick={()=>void toggleConnection()}><CirclePower size={20}/>{connected ? 'Disconnect' : 'Secure my connection'}</button>
      <div className="metrics"><div><Gauge/><b>{pingLabel(locations.find(x=>x.id===selected.id)?.ping)}</b><small>Latency</small></div><div><Shield/><b>{connected ? 'Protected' : 'Direct'}</b><small>Route</small></div></div>
    </section>
  </main>;
}

createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>);
