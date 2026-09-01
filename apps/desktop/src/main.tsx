import React, { useMemo, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { invoke } from '@tauri-apps/api/core';
import { ChevronLeft, ChevronRight, CirclePower, Gauge, LockKeyhole, MapPin, Search, Settings, Shield, Star, Wifi } from 'lucide-react';
import './styles.css';

type Page = 'home' | 'locations' | 'settings' | 'split' | 'devices' | 'advanced';

type Location = { id: string; country: string; city: string; ping: number; favorite?: boolean };
const demoLocations: Location[] = [
  { id: 'ee-tll', country: 'Estonia', city: 'Tallinn', ping: 82, favorite: true },
  { id: 'fi-hel', country: 'Finland', city: 'Helsinki', ping: 91 },
  { id: 'de-ber', country: 'Germany', city: 'Berlin', ping: 104 },
  { id: 'nl-ams', country: 'Netherlands', city: 'Amsterdam', ping: 111 },
];

function Row({ title, subtitle, onClick, right }: { title: string; subtitle?: string; onClick?: () => void; right?: React.ReactNode }) {
  return <button className="settings-row" onClick={onClick}><span><b>{title}</b>{subtitle && <small>{subtitle}</small>}</span>{right ?? <ChevronRight size={18}/>}</button>;
}

function App() {
  const [page, setPage] = useState<Page>('home');
  const [connected, setConnected] = useState(false);
  const [selected, setSelected] = useState(demoLocations[0]);
  const [query, setQuery] = useState('');
  const filtered = useMemo(() => demoLocations.filter(x => `${x.country} ${x.city}`.toLowerCase().includes(query.toLowerCase())), [query]);

  async function action(name: string) {
    try {
      const result = await invoke<string>('helper_action', { action: name, args: [] });
      if (name === 'disconnect') setConnected(false);
      if (name === 'connect') setConnected(result.toLowerCase().includes('ok') || result.toLowerCase().includes('established'));
    } catch (e) { console.error(e); }
  }

  const header = (title: string, back: Page) => <header className="topbar"><button className="icon-btn" onClick={() => setPage(back)}><ChevronLeft/></button><h1>{title}</h1><span/></header>;

  if (page === 'locations') return <main className="app-shell">{header('Select location','home')}<section className="page-pad">
    <div className="search"><Search size={17}/><input value={query} onChange={e=>setQuery(e.target.value)} placeholder="Search country or city"/></div>
    <div className="section-title">LOCATIONS</div>
    <div className="location-list">{filtered.map(loc => <button key={loc.id} className="location-row" onClick={()=>{setSelected(loc);setPage('home')}}><span className="flag-dot"/><span className="loc-main"><b>{loc.country}</b><small>{loc.city}</small></span><span className="ping">{loc.ping} ms</span>{loc.favorite ? <Star size={16} fill="currentColor"/> : <Star size={16}/>}</button>)}</div>
  </section></main>;

  if (page === 'settings') return <main className="app-shell">{header('Settings','home')}<section className="page-pad stack-list">
    <Row title="VPN settings" subtitle="Kill switch, DNS, transport and Iran bypass" onClick={()=>setPage('advanced')}/>
    <Row title="Split tunneling" subtitle="Apps, domains, IPs and Iran direct routing" onClick={()=>setPage('split')}/>
    <Row title="Hotspot & devices" subtitle="Per-device VPN, Direct, Block, quota and guest" onClick={()=>setPage('devices')}/>
    <Row title="Advanced" subtitle="Auto-connect, lockdown, diagnostics and recovery" onClick={()=>setPage('advanced')}/>
  </section></main>;

  if (page === 'split') return <main className="app-shell">{header('Split tunneling','settings')}<section className="page-pad stack-list">
    <div className="info-card"><Shield size={20}/><span><b>App-based split tunneling</b><small>Choose Linux apps that bypass VPN while everything else stays protected.</small></span></div>
    <Row title="Applications" subtitle="Select installed apps to bypass or force through VPN"/>
    <Row title="Iran bypass" subtitle="Route Iranian destinations directly" right={<input type="checkbox" defaultChecked/>}/>
    <Row title="Domain / IP policies" subtitle="Direct, VPN or Block rules"/>
  </section></main>;

  if (page === 'devices') return <main className="app-shell">{header('Hotspot & devices','settings')}<section className="page-pad stack-list">
    <div className="info-card"><Wifi size={20}/><span><b>Protected hotspot</b><small>Manage phones and clients individually.</small></span></div>
    <Row title="Connected devices" subtitle="VPN / Direct / Block / Pause"/>
    <Row title="Guest hotspot" subtitle="Temporary SSID with auto-expiry"/>
    <Row title="Force DNS" subtitle="Prevent client DNS leaks" right={<input type="checkbox" defaultChecked/>}/>
  </section></main>;

  if (page === 'advanced') return <main className="app-shell">{header('Advanced settings','settings')}<section className="page-pad stack-list">
    <Row title="Launch at startup" subtitle="Start MilMit Secure when you sign in" right={<input type="checkbox"/>}/>
    <Row title="Auto-connect" subtitle="Protect traffic automatically after startup" right={<input type="checkbox"/>}/>
    <Row title="Lockdown mode" subtitle="Block network unless the VPN is connected" right={<input type="checkbox"/>}/>
    <Row title="Custom location lists" subtitle="Create reusable server groups"/>
    <Row title="Diagnostics" subtitle="Health, latency, routes, DNS and support bundle"/>
  </section></main>;

  return <main className={`app-shell ${connected ? 'connected' : ''}`}>
    <header className="topbar"><div className="brand"><Shield size={20}/><b>MilMit Secure</b></div><button className="icon-btn" onClick={()=>setPage('settings')}><Settings/></button></header>
    <section className="hero-area"><div className="status-orb"><LockKeyhole size={44}/></div><h2>{connected ? 'SECURE CONNECTION' : 'UNSECURED CONNECTION'}</h2><p>{connected ? 'Your traffic is protected' : 'Connect to protect your traffic'}</p></section>
    <section className="home-actions">
      <button className="location-card" onClick={()=>setPage('locations')}><MapPin/><span><b>{selected.country}</b><small>{selected.city}</small></span><span className="ping">{selected.ping} ms</span><ChevronRight/></button>
      <button className={connected ? 'disconnect-btn' : 'connect-btn'} onClick={()=>action(connected ? 'disconnect' : 'connect')}><CirclePower size={20}/>{connected ? 'Disconnect' : 'Secure my connection'}</button>
      <div className="metrics"><div><Gauge/><b>{selected.ping} ms</b><small>Latency</small></div><div><Shield/><b>{connected ? 'Protected' : 'Direct'}</b><small>Route</small></div></div>
    </section>
  </main>;
}

createRoot(document.getElementById('root')!).render(<React.StrictMode><App/></React.StrictMode>);
