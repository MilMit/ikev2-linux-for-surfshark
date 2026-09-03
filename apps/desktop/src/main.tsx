import React, { useEffect, useMemo, useState, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import { invoke } from '@tauri-apps/api/core';
import {
  Activity,
  AlertTriangle,
  ArrowDown,
  ArrowUp,
  BarChart3,
  Bot,
  CheckCircle2,
  ChevronLeft,
  ChevronRight,
  CirclePower,
  Gauge,
  Globe,
  Key,
  ListPlus,
  LoaderCircle,
  Laptop,
  MapPin,
  Network,
  Plus,
  RefreshCw,
  Search,
  Server,
  Settings,
  Shield,
  ShieldAlert,
  ShieldCheck,
  Sparkles,
  Star,
  Terminal,
  Trash2,
  Wifi,
  Zap,
  X,
} from 'lucide-react';
import './styles.css';
import { TrafficChart } from './components/TrafficChart';
import { CredentialsModal } from './components/CredentialsModal';
import { LogTerminal } from './components/LogTerminal';
import { RouteBeam } from './components/RouteBeam';
import { LanguageProvider, useI18n } from './i18n/LanguageContext';

type Page =
  | 'home'
  | 'locations'
  | 'settings'
  | 'vpn'
  | 'split'
  | 'splitApps'
  | 'policies'
  | 'devices'
  | 'deviceList'
  | 'guest'
  | 'advanced'
  | 'customLists'
  | 'diagnostics'
  | 'usage';

interface Location {
  id: string;
  country: string;
  city: string;
  host: string;
  ping?: number | null;
}

interface ConnState {
  connected: boolean;
  state: string;
  public_ip?: string | null;
  exit_country?: string | null;
  latency_ms?: number | null;
}

interface PingResult {
  id: string;
  ping: number | null;
}

interface CountryPingCache {
  ts: number;
  values: Record<string, number | null>;
}

interface OperationState {
  state: 'idle' | 'running' | 'success' | 'error';
  title: string;
  detail: string;
}

interface TrafficSnapshot {
  connected: boolean;
  rx_bytes: number;
  tx_bytes: number;
  rx_bps: number;
  tx_bps: number;
  all_rx_bytes: number;
  all_tx_bytes: number;
  day_rx_bytes: number;
  day_tx_bytes: number;
  month_rx_bytes: number;
  month_tx_bytes: number;
}

interface UsageTotals {
  allRx: number;
  allTx: number;
  dayRx: number;
  dayTx: number;
  monthRx: number;
  monthTx: number;
}

interface DesktopApp {
  id: string;
  name: string;
  icon: string;
  exec: string;
}

interface DesktopFeatureState {
  auto_connect?: boolean;
  lockdown?: boolean;
  lockdown_allow_iran?: boolean;
  lockdown_blocking?: boolean;
  direct_namespace?: boolean;
}

interface CustomBypassRule {
  target: string;
  type: 'domain' | 'ip' | 'cidr';
  resolved_ips?: string[];
  added_at?: string;
}

interface LocationList {
  id: string;
  name: string;
  location_ids: string[];
}

interface RouterState {
  hotspot?: {
    iface?: string;
    subnet?: string;
    clients?: { ip: string; mac: string; state: string }[];
    client_count?: number;
  };
  config?: {
    devices?: Record<
      string,
      {
        policy?: string;
        speed_kbit?: number;
        quota_mb?: number;
        quota_action?: string;
        paused?: boolean;
      }
    >;
    force_dns?: boolean;
    block_quic?: boolean;
    client_isolation?: boolean;
    ipv6_policy?: string;
  };
  usage?: {
    devices?: Record<
      string,
      {
        up_bytes?: number;
        down_bytes?: number;
        day_up_bytes?: number;
        day_down_bytes?: number;
        bytes_seen?: number;
      }
    >;
  };
}

interface DeviceDraft {
  speed: string;
  quota: string;
}

interface RoutingModeStatus {
  ok?: boolean;
  routing_mode?: string;
  connected?: boolean;
  iran_bypass_active?: boolean;
  rules_metadata?: {
    updated_at?: number;
    source?: string;
    cidr_count?: number;
    domain_count?: number;
    mirrors?: Record<string, string>;
  };
}

interface ChatGptTestResult {
  ok?: boolean;
  dns_resolved?: boolean;
  resolved_ips?: string[];
  http_status?: number;
  details?: string;
  latency_ms?: number;
}

const FALLBACK: Location = {
  id: 'ee-tll',
  country: 'Estonia',
  city: 'Tallinn',
  host: 'ee-tll.prod.surfshark.com',
  ping: null,
};

const COUNTRY_CACHE_KEY = 'milmit-country-pings-v2';
const LOCATION_CACHE_KEY = 'milmit-location-pings-v2';
const CACHE_MAX_AGE = 15 * 60 * 1000;

function Row({
  title,
  subtitle,
  onClick,
  right,
  disabled = false,
}: {
  title: string;
  subtitle?: string;
  onClick?: () => void;
  right?: React.ReactNode;
  disabled?: boolean;
}) {
  return (
    <button className="settings-row" disabled={disabled} onClick={onClick}>
      <div className="settings-row-text">
        <b>{title}</b>
        {subtitle && <small>{subtitle}</small>}
      </div>
      {right ?? <ChevronRight size={18} color="var(--text-secondary)" />}
    </button>
  );
}

function ActionRow({
  title,
  subtitle,
  onClick,
  busy,
  icon,
}: {
  title: string;
  subtitle: string;
  onClick: () => void;
  busy: boolean;
  icon?: React.ReactNode;
}) {
  return (
    <Row
      title={title}
      subtitle={subtitle}
      onClick={onClick}
      disabled={busy}
      right={
        busy ? (
          <LoaderCircle className="spin" size={18} color="var(--accent-cyan)" />
        ) : (
          icon ?? <ChevronRight size={18} color="var(--text-secondary)" />
        )
      }
    />
  );
}

function OperationBanner({ op, onDismiss }: { op: OperationState; onDismiss: () => void }) {
  if (op.state === 'idle') return null;
  const icon =
    op.state === 'running' ? (
      <LoaderCircle className="spin" size={18} color="var(--accent-cyan)" />
    ) : op.state === 'success' ? (
      <CheckCircle2 size={18} color="var(--accent-emerald)" />
    ) : (
      <AlertTriangle size={18} color="var(--accent-danger)" />
    );

  return (
    <div className={`operation-banner ${op.state}`} onClick={op.state === 'running' ? undefined : onDismiss}>
      <span>{icon}</span>
      <div>
        <b>{op.title}</b>
        <small>{op.detail}</small>
      </div>
      {op.state !== 'running' && (
        <button className="icon-btn-close" aria-label="Dismiss">
          <X size={16} />
        </button>
      )}
    </div>
  );
}

function Toggle({ on, label }: { on: boolean; label: string }) {
  return (
    <span className={`toggle ${on ? 'on' : ''}`} aria-label={label}>
      <i />
    </span>
  );
}

const pingLabel = (v?: number | null) => (typeof v === 'number' ? `${v} ms` : '—');

function flagFor(id: string) {
  const cc = id.slice(0, 2).toUpperCase();
  return /^[A-Z]{2}$/.test(cc)
    ? String.fromCodePoint(...[...cc].map(c => 127397 + c.charCodeAt(0)))
    : '🌐';
}

function readJson<T>(key: string, fallback: T): T {
  try {
    return JSON.parse(localStorage.getItem(key) || '') as T;
  } catch {
    return fallback;
  }
}

function fmtBytes(n: number) {
  if (!Number.isFinite(n) || n <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let v = n;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toFixed(i >= 3 ? 2 : i === 2 ? 1 : 0)} ${units[i]}`;
}

function fmtRate(n: number) {
  return `${fmtBytes(n)}/s`;
}

function App() {
  const { language, setLanguage, toggleLanguage, t, isRtl } = useI18n();
  const [page, setPage] = useState<Page>('home');
  const [locations, setLocations] = useState<Location[]>([FALLBACK]);
  const [selected, setSelected] = useState<Location>(FALLBACK);
  const [query, setQuery] = useState('');
  const [favorites, setFavorites] = useState<Set<string>>(
    () => new Set(readJson<string[]>('milmit-favorites', []))
  );
  const [recent, setRecent] = useState<string[]>(() =>
    readJson<string[]>('milmit-recent-locations', [])
  );
  const cachedCountries = readJson<CountryPingCache>(COUNTRY_CACHE_KEY, { ts: 0, values: {} });
  const [countryPings, setCountryPings] = useState<Record<string, number | null>>(
    cachedCountries.values || {}
  );
  const [countryScanning, setCountryScanning] = useState(false);
  const [scanning, setScanning] = useState(false);
  const [scanProgress, setScanProgress] = useState('');
  const [busy, setBusy] = useState(false);
  const [phase, setPhase] = useState('');
  const [conn, setConn] = useState<ConnState>({ connected: false, state: 'DISCONNECTED' });
  const [traffic, setTraffic] = useState<TrafficSnapshot>({
    connected: false,
    rx_bytes: 0,
    tx_bytes: 0,
    rx_bps: 0,
    tx_bps: 0,
    all_rx_bytes: 0,
    all_tx_bytes: 0,
    day_rx_bytes: 0,
    day_tx_bytes: 0,
    month_rx_bytes: 0,
    month_tx_bytes: 0,
  });
  const [trafficHistory, setTrafficHistory] = useState<{ rx: number; tx: number }[]>([]);
  const [usage, setUsage] = useState<UsageTotals>({
    allRx: 0,
    allTx: 0,
    dayRx: 0,
    dayTx: 0,
    monthRx: 0,
    monthTx: 0,
  });
  const [toast, setToast] = useState('');
  const [diag, setDiag] = useState('');
  const [policyTarget, setPolicyTarget] = useState('');
  const [guestMinutes, setGuestMinutes] = useState('60');
  const [guestSsid, setGuestSsid] = useState('MilMit Guest');
  const [operation, setOperation] = useState<OperationState>({ state: 'idle', title: '', detail: '' });
  const [desktopFeatures, setDesktopFeatures] = useState<DesktopFeatureState>({});
  const [launchStartup, setLaunchStartup] = useState(false);
  const [apps, setApps] = useState<DesktopApp[]>([]);
  const [appQuery, setAppQuery] = useState('');
  const [directApps, setDirectApps] = useState<Set<string>>(
    () => new Set(readJson<string[]>('milmit-direct-apps', []))
  );
  const [lists, setLists] = useState<LocationList[]>([]);
  const [newListName, setNewListName] = useState('');
  const [router, setRouter] = useState<RouterState>({});
  const [deviceDrafts, setDeviceDrafts] = useState<Record<string, DeviceDraft>>({});
  const [routingMode, setRoutingMode] = useState<RoutingModeStatus>({
    routing_mode: 'iran_direct',
    iran_bypass_active: true,
  });
  const [updatingRules, setUpdatingRules] = useState(false);
  const [chatGptTesting, setChatGptTesting] = useState(false);
  const [chatGptResult, setChatGptResult] = useState<ChatGptTestResult | null>(null);
  const [dnsRepairing, setDnsRepairing] = useState(false);
  const [customRules, setCustomRules] = useState<CustomBypassRule[]>([]);
  const [customInput, setCustomInput] = useState('');
  const [addingCustomRule, setAddingCustomRule] = useState(false);
  const [fastestConnecting, setFastestConnecting] = useState(false);

  // Modals & Drawers
  const [credentialsOpen, setCredentialsOpen] = useState(false);
  const [terminalOpen, setTerminalOpen] = useState(false);

  // Load locations on startup
  useEffect(() => {
    void invoke<Location[]>('list_locations')
      .then(list => {
        if (!list.length) return;
        const saved = readJson<{ ts: number; values: Record<string, number | null> }>(
          LOCATION_CACHE_KEY,
          { ts: 0, values: {} }
        );
        const sorted = [...list]
          .sort((a, b) => a.country.localeCompare(b.country) || a.city.localeCompare(b.city))
          .map(x => ({ ...x, ping: saved.values?.[x.id] ?? null }));
        setLocations(sorted);
        const chosen = localStorage.getItem('milmit-selected-location');
        setSelected(
          sorted.find(x => x.id === chosen) || sorted.find(x => x.id === 'ee-tll') || sorted[0]
        );
      })
      .catch(e => setToast(`Could not load locations: ${String(e)}`));
  }, []);

  // Poll connection & traffic state
  useEffect(() => {
    const refresh = () => {
      void invoke<ConnState>('connection_state')
        .then(s => {
          setConn(s);
          if (s.connected && phase) setPhase('');
        })
        .catch(() => {});

      void invoke<TrafficSnapshot>('traffic_snapshot')
        .then(s => {
          setTraffic(s);
          setTrafficHistory(prev => [...prev.slice(-23), { rx: s.rx_bps, tx: s.tx_bps }]);
          setUsage({
            allRx: s.all_rx_bytes,
            allTx: s.all_tx_bytes,
            dayRx: s.day_rx_bytes,
            dayTx: s.day_tx_bytes,
            monthRx: s.month_rx_bytes,
            monthTx: s.month_tx_bytes,
          });
        })
        .catch(() => {});
    };

    refresh();
    const t = setInterval(refresh, 2200);
    return () => clearInterval(t);
  }, [phase]);

  // Toast Auto-Dismiss
  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(''), 4200);
    return () => clearTimeout(t);
  }, [toast]);

  // Page Specific Inits
  useEffect(() => {
    if (page === 'vpn') {
      void invoke<DesktopFeatureState>('desktop_feature_state')
        .then(setDesktopFeatures)
        .catch(() => {});
      void invoke<boolean>('launch_at_startup_enabled')
        .then(setLaunchStartup)
        .catch(() => {});
    }
    if (page === 'splitApps' && apps.length === 0) {
      void invoke<DesktopApp[]>('list_desktop_apps')
        .then(setApps)
        .catch(e => setToast(String(e)));
    }
    if (page === 'customLists') {
      void invoke<LocationList[]>('get_location_lists')
        .then(setLists)
        .catch(() => {});
    }
    if (page === 'split') {
      void loadRoutingMode();
      void loadCustomRules();
    }
    if (page === 'deviceList') {
      void loadRouter();
    }
  }, [page]);

  const filtered = useMemo(
    () =>
      locations.filter(x =>
        `${x.country} ${x.city} ${x.host}`.toLowerCase().includes(query.toLowerCase())
      ),
    [locations, query]
  );

  const grouped = useMemo(() => {
    const m = new Map<string, Location[]>();
    for (const l of filtered) {
      const a = m.get(l.country) || [];
      a.push(l);
      m.set(l.country, a);
    }
    return [...m.entries()];
  }, [filtered]);

  const allGrouped = useMemo(() => {
    const m = new Map<string, Location[]>();
    for (const l of locations) {
      const a = m.get(l.country) || [];
      a.push(l);
      m.set(l.country, a);
    }
    return [...m.entries()];
  }, [locations]);

  const recentLocations = useMemo(
    () => recent.map(id => locations.find(x => x.id === id)).filter(Boolean) as Location[],
    [recent, locations]
  );

  const favoriteLocations = useMemo(
    () => locations.filter(x => favorites.has(x.id)),
    [favorites, locations]
  );

  const visibleApps = useMemo(
    () =>
      apps.filter(a =>
        `${a.name} ${a.id} ${a.exec}`.toLowerCase().includes(appQuery.toLowerCase())
      ),
    [apps, appQuery]
  );

  function saveLocationPings(next: Location[]) {
    const values: Record<string, number | null> = {};
    for (const l of next) if (typeof l.ping === 'number') values[l.id] = l.ping;
    localStorage.setItem(LOCATION_CACHE_KEY, JSON.stringify({ ts: Date.now(), values }));
  }

  function applyPings(results: PingResult[]) {
    setLocations(prev => {
      const map = new Map(results.map(x => [x.id, x.ping]));
      const next = prev.map(l => (map.has(l.id) ? { ...l, ping: map.get(l.id) ?? null } : l));
      saveLocationPings(next);
      return next;
    });
  }

  async function batchPing(list: Location[]): Promise<PingResult[]> {
    if (!list.length) return [];
    return invoke<PingResult[]>('ping_locations_batch', {
      items: list.map(x => ({ id: x.id, host: x.host })),
    });
  }

  async function scanCountryHeaders(force = false) {
    if (countryScanning || locations.length < 2) return;
    const cache = readJson<CountryPingCache>(COUNTRY_CACHE_KEY, { ts: 0, values: {} });
    if (!force && Date.now() - cache.ts < CACHE_MAX_AGE && Object.keys(cache.values || {}).length > 10) {
      setCountryPings(cache.values);
      return;
    }
    setCountryScanning(true);
    try {
      const reps = allGrouped.map(([, locs]) => locs.find(x => typeof x.ping === 'number') || locs[0]);
      const results = await batchPing(reps);
      const byId = new Map(results.map(x => [x.id, x.ping]));
      const next: Record<string, number | null> = {};
      for (const [country, locs] of allGrouped) {
        const rep = locs.find(x => typeof x.ping === 'number') || locs[0];
        next[country] = byId.get(rep.id) ?? rep.ping ?? null;
      }
      setCountryPings(next);
      localStorage.setItem(COUNTRY_CACHE_KEY, JSON.stringify({ ts: Date.now(), values: next }));
      applyPings(results);
    } catch {
    } finally {
      setCountryScanning(false);
    }
  }

  useEffect(() => {
    if (page === 'locations' && locations.length > 1) void scanCountryHeaders(false);
  }, [page, locations.length]);

  async function scanList(list: Location[], label = 'Scanning latency') {
    if (!list.length || scanning) return;
    setScanning(true);
    let done = 0;
    try {
      for (let i = 0; i < list.length; i += 24) {
        const chunk = list.slice(i, i + 24);
        const res = await batchPing(chunk);
        applyPings(res);
        done += chunk.length;
        setScanProgress(`${label} · ${done}/${list.length}`);
        await new Promise(r => setTimeout(r, 0));
      }
    } finally {
      setScanning(false);
      setScanProgress('');
    }
  }

  async function scanAll(selectFastest = false) {
    await scanList(locations, selectFastest ? 'Finding fastest' : 'Scanning all');
    if (selectFastest) {
      setLocations(current => {
        const best = [...current]
          .filter(x => typeof x.ping === 'number')
          .sort((a, b) => (a.ping ?? 99999) - (b.ping ?? 99999))[0];
        if (best) {
          chooseLocation(best, false);
          setToast(`Fastest server selected: ${best.country} · ${best.city} (${best.ping} ms)`);
        }
        return current;
      });
    }
  }

  async function smartQuickConnect() {
    setToast('Finding best server with lowest latency…');
    await scanList(locations.slice(0, 16), 'Smart scan');
    const best = [...locations]
      .filter(x => typeof x.ping === 'number')
      .sort((a, b) => (a.ping ?? 99999) - (b.ping ?? 99999))[0];
    if (best) {
      chooseLocation(best, false);
      void connectTo(best);
    } else {
      void toggleConnection();
    }
  }

  function scanCountry(locs: Location[]) {
    const needed = locs.filter(x => typeof x.ping !== 'number');
    if (needed.length && !scanning) void scanList(needed, 'Scanning country');
  }

  function countryPing(country: string, locs: Location[]) {
    const measured = locs.map(x => x.ping).filter((v): v is number => typeof v === 'number');
    return measured.length ? Math.min(...measured) : countryPings[country];
  }

  function toggleFavorite(id: string) {
    setFavorites(prev => {
      const n = new Set(prev);
      n.has(id) ? n.delete(id) : n.add(id);
      localStorage.setItem('milmit-favorites', JSON.stringify([...n]));
      return n;
    });
  }

  function chooseLocation(loc: Location, goHome = true) {
    setSelected(loc);
    localStorage.setItem('milmit-selected-location', loc.id);
    setRecent(prev => {
      const n = [loc.id, ...prev.filter(x => x !== loc.id)].slice(0, 8);
      localStorage.setItem('milmit-recent-locations', JSON.stringify(n));
      return n;
    });
    if (goHome) setPage('home');
  }

  async function helper(
    name: string,
    args: string[] = [],
    show = false,
    progressTitle?: string,
    progressDetail?: string,
    successDetail?: string
  ) {
    setBusy(true);
    if (progressTitle)
      setOperation({
        state: 'running',
        title: progressTitle,
        detail: progressDetail || 'Please wait while MilMit Secure applies the change.',
      });
    try {
      const r = await invoke<string>('helper_action', { action: name, args });
      if (show) setDiag(r || 'Completed successfully.');
      if (progressTitle)
        setOperation({
          state: 'success',
          title: `${progressTitle} — done`,
          detail: successDetail || 'The requested change was applied successfully.',
        });
      else setToast(`${name.replaceAll('-', ' ')} completed`);
      return r;
    } catch (e) {
      const t = String(e);
      if (show) setDiag(t);
      if (progressTitle)
        setOperation({
          state: 'error',
          title: `${progressTitle} — failed`,
          detail: t.length > 190 ? `${t.slice(0, 190)}…` : t,
        });
      else setToast(t.length > 120 ? `${t.slice(0, 120)}…` : t);
      throw e;
    } finally {
      setBusy(false);
    }
  }

  async function cancelInFlightConnection() {
    setPhase('CANCELLING');
    try {
      await invoke('cancel_connect');
      setToast('Connection cancelled.');
    } catch (e) {
      setToast(`Cancel failed: ${String(e)}`);
    } finally {
      setTimeout(() => {
        setPhase('');
        void invoke<ConnState>('connection_state').then(setConn);
      }, 700);
    }
  }

  async function connectTo(loc: Location) {
    try {
      setPhase('PREPARING');
      const r = await invoke<string>('connect_location', { id: loc.id });
      setToast(
        r.includes(`IDENTITY=${loc.host}`)
          ? `Protected via ${loc.country} · ${loc.city}`
          : 'Connected and verified'
      );
      setTimeout(() => void invoke<ConnState>('connection_state').then(setConn), 500);
    } catch (e) {
      setToast(String(e).slice(0, 170));
    } finally {
      setPhase('');
    }
  }

  async function toggleConnection() {
    if (phase) {
      // In flight, click cancels
      await cancelInFlightConnection();
      return;
    }

    try {
      if (conn.connected) {
        setPhase('DISCONNECTING');
        await helper('disconnect');
      } else {
        await connectTo(selected);
      }
      setTimeout(() => void invoke<ConnState>('connection_state').then(setConn), 500);
    } catch (e) {
      setToast(String(e).slice(0, 170));
    } finally {
      setPhase('');
    }
  }

  async function runPing(kind: 'internet' | 'vpn' | 'location') {
    setBusy(true);
    setDiag('Running 8-packet ping…');
    try {
      setDiag(await invoke<string>('ping_report', { kind, host: selected.host }));
      setPage('diagnostics');
    } catch (e) {
      setDiag(String(e));
      setPage('diagnostics');
    } finally {
      setBusy(false);
    }
  }

  function requireEmergencyRecovery() {
    if (
      !window.confirm(
        'Emergency network recovery removes MilMit VPN routing and restores direct networking. Continue?'
      )
    )
      return;
    void helper(
      'emergency-stop',
      [],
      false,
      'Emergency network recovery',
      'Removing MilMit routing, firewall hooks and recovery state…',
      'MilMit VPN routing was removed and direct networking was restored.'
    );
  }

  async function setDesktopFlag(kind: 'auto-connect' | 'lockdown', value: boolean) {
    if (
      kind === 'lockdown' &&
      value &&
      !window.confirm(
        'Lockdown blocks normal Internet whenever the VPN is disconnected. Local network access and the saved VPN endpoint remain allowed. Enable it?'
      )
    )
      return;
    await helper(
      kind,
      [value ? '1' : '0'],
      false,
      kind === 'lockdown' ? 'Changing Lockdown mode' : 'Changing Auto-connect',
      value ? 'Enabling protection…' : 'Disabling protection…',
      `${kind === 'lockdown' ? 'Lockdown' : 'Auto-connect'} is now ${value ? 'enabled' : 'disabled'}.`
    );
    setDesktopFeatures(await invoke<DesktopFeatureState>('desktop_feature_state'));
  }

  async function setStartup(value: boolean) {
    setBusy(true);
    try {
      await invoke('set_launch_at_startup', { enabled: value });
      setLaunchStartup(value);
      setOperation({
        state: 'success',
        title: 'Launch at startup updated',
        detail: value
          ? 'MilMit Secure will launch when you sign in.'
          : 'MilMit Secure will no longer launch automatically.',
      });
    } catch (e) {
      setOperation({ state: 'error', title: 'Startup setting failed', detail: String(e) });
    } finally {
      setBusy(false);
    }
  }

  function toggleDirectApp(id: string) {
    setDirectApps(prev => {
      const n = new Set(prev);
      n.has(id) ? n.delete(id) : n.add(id);
      localStorage.setItem('milmit-direct-apps', JSON.stringify([...n]));
      return n;
    });
  }

  async function launchDirect(app: DesktopApp) {
    await helper(
      'app-direct-launch',
      [app.id],
      false,
      `Launching ${app.name} Direct`,
      'Creating an isolated Direct network namespace and starting the application outside the VPN…',
      `${app.name} was launched in the Direct split-tunnel namespace.`
    );
  }

  async function persistLists(next: LocationList[]) {
    setLists(next);
    await invoke('save_location_lists', { lists: next });
  }

  async function createList() {
    const name = newListName.trim();
    if (!name) return;
    const item: LocationList = {
      id: `list-${Date.now()}`,
      name,
      location_ids: [selected.id],
    };
    await persistLists([...lists, item]);
    setNewListName('');
    setToast(`Created custom list: ${name}`);
  }

  async function addSelectedToList(id: string) {
    await persistLists(
      lists.map(l =>
        l.id === id ? { ...l, location_ids: [...new Set([...l.location_ids, selected.id])] } : l
      )
    );
    setToast(`Added ${selected.city} to list`);
  }

  async function removeList(id: string) {
    await persistLists(lists.filter(l => l.id !== id));
  }

  async function loadRoutingMode() {
    try {
      const raw = await invoke<string>('helper_action', { action: 'routing-mode-status', args: [] });
      const parsed = JSON.parse(raw) as RoutingModeStatus;
      setRoutingMode(parsed);
    } catch {
      // fallback
    }
  }

  async function toggleRoutingMode() {
    const current = routingMode.routing_mode || 'iran_direct';
    const next = current === 'iran_direct' ? 'vpn_all' : 'iran_direct';
    setBusy(true);
    try {
      await helper(
        'set-routing-mode',
        [next],
        false,
        next === 'iran_direct' ? 'Enabling Iran Domestic Bypass' : 'Enabling Full VPN Tunnel',
        next === 'iran_direct'
          ? 'Routing domestic Iran traffic directly, international traffic via VPN…'
          : 'Routing 100% of all Ubuntu traffic through the encrypted VPN tunnel…',
        next === 'iran_direct' ? 'Iran direct bypass enabled.' : 'Full VPN tunnel enabled.'
      );
      await loadRoutingMode();
    } catch (e) {
      setToast(`Error changing routing mode: ${String(e)}`);
    } finally {
      setBusy(false);
    }
  }

  async function loadCustomRules() {
    try {
      const raw = await invoke<string>('helper_action', { action: 'custom-rules-get', args: [] });
      const data = JSON.parse(raw);
      if (data.ok && Array.isArray(data.rules)) {
        setCustomRules(data.rules);
      }
    } catch {
      // ignore
    }
  }

  async function addCustomRule() {
    const val = customInput.trim();
    if (!val) return;
    setAddingCustomRule(true);
    try {
      const raw = await invoke<string>('helper_action', { action: 'custom-rules-add', args: [val] });
      const data = JSON.parse(raw);
      if (data.ok) {
        setCustomInput('');
        setToast(`Added ${val} to custom bypass`);
        await loadCustomRules();
      } else {
        setToast(data.error || 'Failed to add rule');
      }
    } catch (e) {
      setToast(String(e));
    } finally {
      setAddingCustomRule(false);
    }
  }

  async function removeCustomRule(target: string) {
    try {
      await invoke<string>('helper_action', { action: 'custom-rules-remove', args: [target] });
      setToast(`Removed ${target}`);
      await loadCustomRules();
    } catch (e) {
      setToast(String(e));
    }
  }

  async function autoConnectFastest() {
    setFastestConnecting(true);
    setToast('⚡ Probing low-latency edge servers…');
    try {
      const candidates = ['tr-ist', 'de-fra', 'nl-ams', 'ch-zur', 'ee-tll', 'ae-dxb', 'fi-hel', 'pl-waw'];
      const targets = locations.filter(l => candidates.includes(l.id));
      const pool = targets.length > 0 ? targets : locations.slice(0, 10);

      const pingReqs = pool.map(l => ({ id: l.id, host: l.host }));
      const results = await invoke<{ id: string; ping: number | null }[]>('ping_locations_batch', { items: pingReqs });

      const responsive = results
        .filter(r => typeof r.ping === 'number' && r.ping > 0)
        .sort((a, b) => (a.ping as number) - (b.ping as number));

      if (responsive.length > 0) {
        const best = pool.find(l => l.id === responsive[0].id);
        if (best) {
          setSelected(best);
          setToast(`⚡ Fastest server: ${best.city}, ${best.country} (${responsive[0].ping} ms)`);
          await connectTo(best);
          return;
        }
      }
      await connectTo(selected);
    } catch (e) {
      setToast(`Fastest search: connecting to ${selected.city}`);
      await connectTo(selected);
    } finally {
      setFastestConnecting(false);
    }
  }

  async function updateRules() {
    setUpdatingRules(true);
    try {
      await helper(
        'rules-update',
        [],
        false,
        'Updating Iran Bypass Rules',
        'Downloading latest CIDR prefixes and domain datasets from GitHub…',
        'Iran bypass rules updated successfully.'
      );
      await loadRoutingMode();
      setToast('Iran bypass rules successfully updated to latest snapshot.');
    } catch (e) {
      setToast(`Update failed: ${String(e)}`);
    } finally {
      setUpdatingRules(false);
    }
  }

  function parseChatGptResponse(input: string): ChatGptTestResult {
    try {
      const start = input.indexOf('{');
      const end = input.lastIndexOf('}');
      if (start !== -1 && end !== -1 && end > start) {
        const obj = JSON.parse(input.slice(start, end + 1)) as ChatGptTestResult;
        return obj;
      }
    } catch {
      // fallback
    }
    return { ok: false, details: input };
  }

  async function runChatGptTest() {
    setChatGptTesting(true);
    setChatGptResult(null);
    try {
      const raw = await helper(
        'chatgpt-test',
        [],
        false,
        'Testing ChatGPT & AI Access',
        'Verifying OpenAI DNS and HTTPS endpoints…',
        'ChatGPT connectivity test completed.'
      );
      setChatGptResult(parseChatGptResponse(raw || ''));
    } catch (e) {
      setChatGptResult(parseChatGptResponse(String(e)));
    } finally {
      setChatGptTesting(false);
    }
  }

  async function runDnsRepair() {
    setDnsRepairing(true);
    try {
      await helper(
        'dns-repair',
        [],
        false,
        'Flushing & Repairing DNS',
        'Flushing systemd-resolved and locking VPN DNS on all adapters…',
        'DNS repaired successfully.'
      );
      setToast('DNS cache flushed and secure Surfshark DNS enforced on all adapters.');
    } catch (e) {
      setToast(`DNS repair failed: ${String(e)}`);
    } finally {
      setDnsRepairing(false);
    }
  }

  async function loadRouter() {
    setBusy(true);
    try {
      const r = await invoke<RouterState>('router_state');
      setRouter(r);
      const d: Record<string, DeviceDraft> = {};
      for (const [mac, cfg] of Object.entries(r.config?.devices || {}))
        d[mac] = { speed: String(cfg.speed_kbit || 0), quota: String(cfg.quota_mb || 0) };
      for (const cl of r.hotspot?.clients || []) if (!d[cl.mac]) d[cl.mac] = { speed: '0', quota: '0' };
      setDeviceDrafts(d);
    } catch (e) {
      setToast(String(e));
    } finally {
      setBusy(false);
    }
  }

  async function setDevice(mac: string, policy: string, paused?: boolean) {
    const cfg = router.config?.devices?.[mac] || {};
    const draft = deviceDrafts[mac] || {
      speed: String(cfg.speed_kbit || 0),
      quota: String(cfg.quota_mb || 0),
    };
    await helper(
      'device-set',
      [
        mac,
        policy,
        draft.speed || '0',
        draft.quota || '0',
        cfg.quota_action || 'notify',
        (paused ?? cfg.paused) ? '1' : '0',
      ],
      false,
      'Updating device policy',
      `${mac} → ${policy}${paused ? ' · paused' : ''}`,
      'Device routing policy was applied.'
    );
    await loadRouter();
  }

  async function setRouterOptions(next: Partial<RouterState['config']>) {
    const c = { ...(router.config || {}), ...next };
    await helper(
      'router-options',
      [
        c.force_dns ? '1' : '0',
        c.block_quic ? '1' : '0',
        c.client_isolation ? '1' : '0',
        c.ipv6_policy || 'block',
      ],
      false,
      'Updating hotspot protection',
      'Applying DNS, QUIC, isolation and IPv6 options…',
      'Hotspot protection options were applied.'
    );
    await loadRouter();
  }

  const header = (title: string, back: Page) => (
    <header className="topbar">
      <button className="icon-btn" onClick={() => setPage(back)} aria-label={t('back')}>
        <ChevronLeft size={20} className="chevron-back" />
      </button>
      <h1 className="brand-title">{title}</h1>
      <div className="topbar-actions">
        <button
          className="lang-switch-btn"
          onClick={toggleLanguage}
          title={language === 'fa' ? 'Switch to English' : 'تغییر به زبان فارسی'}
          aria-label={t('language')}
        >
          <Globe size={15} />
          <span className="lang-switch-badge">{language.toUpperCase()}</span>
        </button>
        <button
          className={`icon-btn ${terminalOpen ? 'active' : ''}`}
          onClick={() => setTerminalOpen(!terminalOpen)}
          title={t('terminal')}
        >
          <Terminal size={18} />
        </button>
      </div>
    </header>
  );

  const toastView = toast ? (
    <div className="toast-bar" onClick={() => setToast('')}>
      <CheckCircle2 size={16} color="var(--accent-cyan)" />
      <span>{toast}</span>
    </div>
  ) : null;

  const feedback = (
    <OperationBanner
      op={operation}
      onDismiss={() => setOperation({ state: 'idle', title: '', detail: '' })}
    />
  );

  const locRow = (loc: Location, prefix = '') => (
    <button
      key={`${prefix}${loc.id}`}
      className={`location-row ${selected.id === loc.id ? 'selected-location' : ''}`}
      onClick={() => chooseLocation(loc)}
    >
      <div className="loc-main">
        <b>{loc.city}</b>
        <small>{loc.host}</small>
      </div>
      <span className={`ping-chip ${typeof loc.ping === 'number' ? (loc.ping < 100 ? 'good' : loc.ping < 200 ? 'medium' : 'high') : ''}`}>
        <span className="ping-dot" />
        {pingLabel(loc.ping)}
      </span>
      <span
        className={`star-btn ${favorites.has(loc.id) ? 'active' : ''}`}
        onClick={e => {
          e.stopPropagation();
          toggleFavorite(loc.id);
        }}
      >
        <Star size={16} fill={favorites.has(loc.id) ? 'currentColor' : 'none'} />
      </span>
    </button>
  );

  /* PAGE: LOCATIONS */
  if (page === 'locations')
    return (
      <main className="app-shell">
        {header(t('selectLocation'), 'home')}
        {toastView}
        <section className="page-pad locations-page">
          <div className="search-box">
            <Search size={18} color="var(--text-secondary)" />
            <input
              value={query}
              onChange={e => setQuery(e.target.value)}
              placeholder={t('searchLocations')}
              autoFocus
            />
            {query && (
              <button className="icon-btn-close" onClick={() => setQuery('')}>
                <X size={16} />
              </button>
            )}
          </div>

          <div className="quick-tools-bar">
            <button className="quick-tool-btn" onClick={() => void scanAll(true)} disabled={scanning}>
              <Zap size={14} color="var(--accent-emerald)" />
              <span>{t('tabFast')}</span>
            </button>
            <button className="quick-tool-btn" onClick={() => void scanAll(false)} disabled={scanning}>
              <RefreshCw size={14} className={scanning ? 'spin' : ''} />
              <span>{scanning ? t('probing') : t('pingServers')}</span>
            </button>
            <button
              className="quick-tool-btn"
              onClick={() => void scanCountryHeaders(true)}
              disabled={countryScanning}
            >
              <RefreshCw size={14} className={countryScanning ? 'spin' : ''} />
              <span>{countryScanning ? t('probing') : 'Refresh'}</span>
            </button>
          </div>

          {!query && favoriteLocations.length > 0 && (
            <div className="stack-list">
              <span className="section-title">{t('tabFavorites').toUpperCase()}</span>
              <div className="settings-grid">
                {favoriteLocations.slice(0, 6).map(l => (
                  <div
                    key={`f-${l.id}`}
                    className="settings-row"
                    onClick={() => chooseLocation(l)}
                  >
                    <span className="flag-badge">{flagFor(l.id)}</span>
                    <div className="settings-row-text">
                      <b>{l.country}</b>
                      <small>{l.city}</small>
                    </div>
                    <span className={`ping-chip ${typeof l.ping === 'number' ? (l.ping < 100 ? 'good' : 'medium') : ''}`}>
                      {pingLabel(l.ping)}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}

          {!query && recentLocations.length > 0 && (
            <div className="stack-list">
              <span className="section-title">{t('tabRecent').toUpperCase()}</span>
              <div className="settings-grid">
                {recentLocations.slice(0, 4).map(l => (
                  <div
                    key={`r-${l.id}`}
                    className="settings-row"
                    onClick={() => chooseLocation(l)}
                  >
                    <span className="flag-badge">{flagFor(l.id)}</span>
                    <div className="settings-row-text">
                      <b>{l.country}</b>
                      <small>{l.city}</small>
                    </div>
                    <span className={`ping-chip ${typeof l.ping === 'number' ? (l.ping < 100 ? 'good' : 'medium') : ''}`}>
                      {pingLabel(l.ping)}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}

          <div className="stack-list">
            <span className="section-title">{t('tabAll').toUpperCase()} ({filtered.length} {t('serversCount')})</span>
            {grouped.map(([country, locs]) => (
              <details
                className="country-group"
                key={country}
                open={query.length > 0}
                onToggle={e => {
                  if ((e.currentTarget as HTMLDetailsElement).open) scanCountry(locs);
                }}
              >
                <summary>
                  <ChevronRight className="country-chevron" size={18} />
                  <span className="flag-badge">{flagFor(locs[0].id)}</span>
                  <b>{country}</b>
                  <span className="ping-chip">{pingLabel(countryPing(country, locs))}</span>
                  <span className="country-count">{locs.length}</span>
                </summary>
                <div className="location-list">{locs.map(l => locRow(l))}</div>
              </details>
            ))}
          </div>
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: SETTINGS */
  if (page === 'settings')
    return (
      <main className="app-shell">
        {header(t('settingsTitle'), 'home')}
        {toastView}
        {feedback}
        <section className="page-pad settings-grid">
          {/* Language & Appearance Selection Card */}
          <div className="settings-card no-hover" style={{ gridColumn: '1 / -1', cursor: 'default' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
              <div className="settings-card-icon">
                <Globe size={18} />
              </div>
              <div style={{ textAlign: isRtl ? 'right' : 'left', flex: 1 }}>
                <b>{t('languageTitle')}</b>
                <div style={{ fontSize: '11px', color: 'var(--text-secondary)', marginTop: '2px' }}>
                  {t('languageDesc')}
                </div>
              </div>
            </div>
            <div className="lang-select-group">
              <button
                type="button"
                className={`lang-option-btn ${language === 'fa' ? 'active' : ''}`}
                onClick={() => setLanguage('fa')}
              >
                <span>🇮🇷</span>
                <span>فارسی (Persian)</span>
              </button>
              <button
                type="button"
                className={`lang-option-btn ${language === 'en' ? 'active' : ''}`}
                onClick={() => setLanguage('en')}
              >
                <span>🇬🇧</span>
                <span>English</span>
              </button>
            </div>
          </div>

          <div className="settings-card" onClick={() => setCredentialsOpen(true)}>
            <div className="settings-card-icon">
              <Key size={18} />
            </div>
            <b>{t('credentialsTitle')}</b>
            <small>{t('credentialsDesc')}</small>
          </div>

          <div className="settings-card" onClick={() => setPage('vpn')}>
            <div className="settings-card-icon">
              <ShieldCheck size={18} />
            </div>
            <b>{t('vpnProtectionTitle')}</b>
            <small>{t('vpnProtectionDesc')}</small>
          </div>

          <div className="settings-card" onClick={() => setPage('split')}>
            <div className="settings-card-icon">
              <Laptop size={18} />
            </div>
            <b>{t('splitTunnelingTitle')}</b>
            <small>{t('splitTunnelingDesc')}</small>
          </div>

          <div className="settings-card" onClick={() => setPage('devices')}>
            <div className="settings-card-icon">
              <Wifi size={18} />
            </div>
            <b>{t('devicesTitle')}</b>
            <small>{t('devicesDesc')}</small>
          </div>

          <div className="settings-card" onClick={() => setPage('diagnostics')}>
            <div className="settings-card-icon">
              <Activity size={18} />
            </div>
            <b>{t('diagnosticsTitle')}</b>
            <small>{t('diagnosticsDesc')}</small>
          </div>

          <div className="settings-card" onClick={() => setPage('usage')}>
            <div className="settings-card-icon">
              <BarChart3 size={18} />
            </div>
            <b>{t('usageTitle')}</b>
            <small>{t('usageDesc')}</small>
          </div>

          <div className="settings-card" onClick={() => setPage('advanced')}>
            <div className="settings-card-icon">
              <Server size={18} />
            </div>
            <b>{t('advancedTitle')}</b>
            <small>{t('advancedDesc')}</small>
          </div>
        </section>

        <CredentialsModal
          isOpen={credentialsOpen}
          onClose={() => setCredentialsOpen(false)}
          onSuccess={msg => setToast(msg)}
        />
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: VPN SETTINGS */
  if (page === 'vpn')
    return (
      <main className="app-shell">
        {header(t('vpnProtectionTitle'), 'settings')}
        {toastView}
        {feedback}
        <section className="page-pad stack-list">
          <span className="section-title">AUTOMATION & KILL SWITCH</span>
          <Row
            disabled={busy}
            title="Auto-connect"
            subtitle="Connect verified location automatically on network ready"
            onClick={() => void setDesktopFlag('auto-connect', !desktopFeatures.auto_connect)}
            right={<Toggle on={!!desktopFeatures.auto_connect} label="Auto-connect" />}
          />
          <Row
            disabled={busy}
            title="Launch at Startup"
            subtitle="Start MilMit Secure when you log into your desktop"
            onClick={() => void setStartup(!launchStartup)}
            right={<Toggle on={launchStartup} label="Launch at startup" />}
          />
          <Row
            disabled={busy}
            title="Lockdown Mode (Kill Switch)"
            subtitle={
              desktopFeatures.lockdown_blocking
                ? 'Traffic is actively blocked until VPN connects'
                : 'Block direct Internet access when VPN is disconnected'
            }
            onClick={() => void setDesktopFlag('lockdown', !desktopFeatures.lockdown)}
            right={<Toggle on={!!desktopFeatures.lockdown} label="Lockdown" />}
          />
          {desktopFeatures.lockdown && (
            <Row
              disabled={busy}
              title="Allow Iran Traffic in Kill Switch"
              subtitle="Keep domestic Iranian websites and banking accessible even if VPN drops"
              onClick={async () => {
                const nextVal = !desktopFeatures.lockdown_allow_iran;
                await helper(
                  'lockdown-allow-iran',
                  [nextVal ? '1' : '0'],
                  false,
                  'Kill Switch Policy',
                  'Updating…',
                  'Kill Switch domestic policy updated.'
                );
                setDesktopFeatures(await invoke<DesktopFeatureState>('desktop_feature_state'));
              }}
              right={<Toggle on={desktopFeatures.lockdown_allow_iran !== false} label="Allow Iran" />}
            />
          )}
          <Row
            disabled={true}
            title="System Tray Background Mode"
            subtitle="Closing window minimizes to the top-bar tray near clock to keep VPN alive"
            onClick={() => {}}
            right={<span style={{ fontSize: 11, fontWeight: 600, color: 'var(--accent-emerald)' }}>Active</span>}
          />

          <span className="section-title">MAINTENANCE & REPAIR</span>
          <ActionRow
            busy={busy}
            title="Protection Health Check"
            subtitle="Inspect tunnel, routing tables, DNS and data path"
            onClick={() => {
              setPage('diagnostics');
              void helper(
                'health',
                [],
                true,
                'Checking Protection',
                'Inspecting tunnel and data path…',
                'Protection health check finished.'
              );
            }}
            icon={<Activity size={18} color="var(--accent-cyan)" />}
          />
          <ActionRow
            busy={busy}
            title="Update Iran CIDR Rules"
            subtitle="Download and refresh latest domestic routing rules"
            onClick={() =>
              void helper(
                'rules-update',
                [],
                false,
                'Updating Iran Rules',
                'Downloading and validating rules…',
                'Iran rules updated.'
              )
            }
            icon={<RefreshCw size={18} color="var(--accent-emerald)" />}
          />
          <ActionRow
            busy={busy}
            title="Repair Routing Safely"
            subtitle="Reapply StrongSwan routing policies and firewall marks"
            onClick={() =>
              void helper(
                'apply-safe',
                [],
                false,
                'Repairing Routing',
                'Applying and verifying routing…',
                'Routing protection repaired.'
              )
            }
            icon={<Network size={18} color="var(--accent-cyan)" />}
          />
          <ActionRow
            busy={busy}
            title="Emergency Network Recovery"
            subtitle="Remove MilMit routing rules and recover direct network"
            onClick={requireEmergencyRecovery}
            icon={<AlertTriangle size={18} color="var(--accent-danger)" />}
          />
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: SPLIT TUNNELING & IRAN BYPASS */
  if (page === 'split') {
    const isIranBypassOn = routingMode.routing_mode === 'iran_direct';
    const lastUpdateTs = routingMode.rules_metadata?.updated_at;
    const lastUpdateStr = lastUpdateTs
      ? new Date(lastUpdateTs * 1000).toLocaleString(undefined, {
          year: 'numeric',
          month: 'short',
          day: 'numeric',
          hour: '2-digit',
          minute: '2-digit',
        })
      : 'Built-in Snapshot';

    return (
      <main className="app-shell">
        {header(t('splitTunnelingTitle'), 'settings')}
        {toastView}
        {feedback}
        <section className="page-pad stack-list">
          {/* Main Bypass Card */}
          <div className={`bypass-card ${isIranBypassOn ? 'active' : ''}`}>
            <div className="bypass-card-header" onClick={() => void toggleRoutingMode()}>
              <div className="bypass-card-title">
                <Globe size={22} color={isIranBypassOn ? 'var(--accent-emerald)' : 'var(--text-secondary)'} />
                <div>
                  <b>Iran Domestic Traffic Bypass</b>
                  <small>
                    {isIranBypassOn
                      ? 'Iranian websites, banks & local CDNs bypass VPN directly'
                      : 'All system traffic routes strictly through encrypted VPN'}
                  </small>
                </div>
              </div>
              <Toggle on={isIranBypassOn} label="Iran Domestic Bypass" />
            </div>

            <div
              className="bypass-status-badge"
              style={{
                background: isIranBypassOn ? 'rgba(16, 185, 129, 0.15)' : 'rgba(148, 163, 184, 0.12)',
                color: isIranBypassOn ? 'var(--accent-emerald)' : 'var(--text-secondary)',
                border: isIranBypassOn ? '1px solid rgba(16, 185, 129, 0.3)' : '1px solid rgba(148, 163, 184, 0.25)',
              }}
            >
              <span
                style={{
                  display: 'inline-block',
                  width: 8,
                  height: 8,
                  borderRadius: '50%',
                  background: isIranBypassOn ? 'var(--accent-emerald)' : 'var(--text-secondary)',
                }}
              />
              <b>{isIranBypassOn ? 'Active (iran_direct)' : 'Disabled (vpn_all)'}</b>
            </div>

            <p style={{ margin: '2px 0 0 0', fontSize: '12px', color: 'var(--text-secondary)', lineHeight: 1.5 }}>
              {isIranBypassOn
                ? 'When enabled, domestic Iranian IP blocks and domains route directly through your local ISP connection without encryption latency, while all global traffic is secured via Surfshark.'
                : 'Full Tunnel mode is active. 100% of all outgoing network connections from this Ubuntu machine pass through the encrypted VPN.'}
            </p>
          </div>

          {/* Rules Snapshot & Update Card */}
          <div className="bypass-card">
            <div className="bypass-card-header">
              <div className="bypass-card-title">
                <ShieldCheck size={20} color="var(--accent-cyan)" />
                <div>
                  <b>Bypass Rules & Dataset Details</b>
                  <small>Chocolate4U Clash & V2Ray verified CIDRs</small>
                </div>
              </div>
              <button
                className="quick-tool-btn"
                disabled={updatingRules || busy}
                onClick={() => void updateRules()}
                style={{ padding: '6px 12px', height: 'auto', display: 'flex', alignItems: 'center', gap: 6 }}
              >
                <RefreshCw size={14} className={updatingRules ? 'spin' : ''} />
                <span>{updatingRules ? 'Updating…' : 'Update Rules'}</span>
              </button>
            </div>

            <div className="bypass-stats-grid">
              <div className="bypass-stat-item">
                <span>Last Updated</span>
                <strong>{lastUpdateStr}</strong>
              </div>
              <div className="bypass-stat-item">
                <span>Rule Source</span>
                <strong>{routingMode.rules_metadata?.source || 'Chocolate4U local'}</strong>
              </div>
              <div className="bypass-stat-item">
                <span>IP Prefixes</span>
                <strong>{routingMode.rules_metadata?.cidr_count?.toLocaleString() || '2,200'} CIDRs</strong>
              </div>
              <div className="bypass-stat-item">
                <span>Direct Domains</span>
                <strong>{routingMode.rules_metadata?.domain_count?.toLocaleString() || '41,614'} Domains</strong>
              </div>
            </div>
          </div>

          {/* Custom Bypass Rules Card */}
          <div className="custom-rules-card">
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
              <div>
                <b style={{ fontSize: 13, color: 'var(--text-primary)' }}>Custom Bypass Rules (استثنائات دلخواه)</b>
                <p style={{ fontSize: 11, color: 'var(--text-secondary)', margin: '2px 0 0 0' }}>
                  Add custom domains or IP addresses that should always bypass the VPN
                </p>
              </div>
              <span className="custom-rule-badge">{customRules.length} Added</span>
            </div>

            <div className="custom-rules-input-row">
              <input
                value={customInput}
                onChange={e => setCustomInput(e.target.value)}
                onKeyDown={e => {
                  if (e.key === 'Enter') void addCustomRule();
                }}
                placeholder="Domain or IP (e.g. srbiau.ac.ir, dl.site.com, 1.2.3.4)"
                disabled={addingCustomRule}
              />
              <button
                className="custom-rules-add-btn"
                disabled={addingCustomRule || !customInput.trim()}
                onClick={() => void addCustomRule()}
              >
                <Plus size={14} />
                <span>{addingCustomRule ? 'Adding…' : 'Add Rule'}</span>
              </button>
            </div>

            {customRules.length > 0 ? (
              <div className="custom-rules-list">
                {customRules.map(r => (
                  <div className="custom-rule-item" key={r.target}>
                    <div className="custom-rule-target">
                      <span className="custom-rule-badge">{r.type}</span>
                      <span>{r.target}</span>
                      {r.resolved_ips && r.resolved_ips.length > 0 && (
                        <small style={{ color: 'var(--text-muted)' }}>({r.resolved_ips.length} IPs)</small>
                      )}
                    </div>
                    <button
                      className="custom-rule-del"
                      title="Remove Rule"
                      onClick={() => void removeCustomRule(r.target)}
                    >
                      <Trash2 size={14} />
                    </button>
                  </div>
                ))}
              </div>
            ) : (
              <small style={{ color: 'var(--text-muted)', textAlign: 'center', padding: '6px 0' }}>
                No custom domains or IPs added yet. Type above to add your first rule.
              </small>
            )}
          </div>

          <span className="section-title">CUSTOM APP & DOMAIN ROUTING</span>

          <Row
            title="Application Launcher"
            subtitle={`${directApps.size} apps configured for isolated Direct Launch`}
            onClick={() => setPage('splitApps')}
            right={<Laptop size={18} color="var(--accent-cyan)" />}
          />
          <Row
            title="Custom Domain & IP Rules"
            subtitle="Force VPN, Direct bypass or Block custom domain/IP targets"
            onClick={() => setPage('policies')}
            right={<Network size={18} color="var(--accent-emerald)" />}
          />

          <div className="credentials-note-box" style={{ marginTop: 6 }}>
            <Shield size={20} />
            <div>
              <b>Isolated Network Namespaces</b>
              <p>
                Applications launched via Direct App Launcher run in isolated network namespaces
                with dedicated loopback and virtual interfaces to guarantee zero DNS or IP leaks.
              </p>
            </div>
          </div>
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );
  }

  /* PAGE: SPLIT APPS */
  if (page === 'splitApps')
    return (
      <main className="app-shell">
        {header(t('directAppLauncher'), 'split')}
        {toastView}
        {feedback}
        <section className="page-pad stack-list">
          <div className="search-box">
            <Search size={18} color="var(--text-secondary)" />
            <input
              value={appQuery}
              onChange={e => setAppQuery(e.target.value)}
              placeholder="Search desktop applications (e.g. Steam, Firefox)…"
            />
          </div>

          <div className="stack-list">
            {visibleApps.map(app => (
              <div className="settings-row" key={app.id}>
                <div className="node-icon-box">
                  <b>{app.name.slice(0, 1).toUpperCase()}</b>
                </div>
                <div className="settings-row-text">
                  <b>{app.name}</b>
                  <small>{app.id}</small>
                </div>
                <button
                  className="quick-tool-btn"
                  disabled={busy}
                  onClick={() => void launchDirect(app)}
                >
                  <Zap size={14} color="var(--accent-emerald)" />
                  <span>Launch Direct</span>
                </button>
              </div>
            ))}
          </div>
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: DOMAIN / IP POLICIES */
  if (page === 'policies')
    return (
      <main className="app-shell">
        {header(t('domainIpPolicies'), 'split')}
        {toastView}
        {feedback}
        <section className="page-pad stack-list">
          <div className="input-group">
            <label>Domain, IP Address or CIDR Subnet</label>
            <input
              value={policyTarget}
              onChange={e => setPolicyTarget(e.target.value)}
              placeholder="e.g. example.com or 192.168.1.0/24"
            />
          </div>
          <div className="quick-tools-bar">
            <button
              className="quick-tool-btn"
              disabled={busy || !policyTarget}
              onClick={() =>
                void helper(
                  'policy-add',
                  [policyTarget, 'direct', 'both'],
                  false,
                  'Adding Direct Rule',
                  `Routing ${policyTarget} outside VPN…`,
                  'Direct policy applied.'
                )
              }
            >
              Bypass VPN
            </button>
            <button
              className="quick-tool-btn"
              disabled={busy || !policyTarget}
              onClick={() =>
                void helper(
                  'policy-add',
                  [policyTarget, 'vpn', 'both'],
                  false,
                  'Adding Force VPN Rule',
                  `Forcing ${policyTarget} through VPN…`,
                  'Force VPN policy applied.'
                )
              }
            >
              Force VPN
            </button>
            <button
              className="quick-tool-btn"
              disabled={busy || !policyTarget}
              onClick={() =>
                void helper(
                  'policy-add',
                  [policyTarget, 'block', 'both'],
                  false,
                  'Adding Block Rule',
                  `Blocking ${policyTarget}…`,
                  'Block policy applied.'
                )
              }
            >
              Block
            </button>
          </div>
          <button
            className="btn-secondary"
            disabled={busy || !policyTarget}
            onClick={() =>
              void helper(
                'route-explain',
                [policyTarget],
                true,
                'Explaining Route',
                'Checking policy table…',
                'Route explanation finished.'
              ).then(() => setPage('diagnostics'))
            }
          >
            Explain Routing Decision
          </button>
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: DEVICES & HOTSPOT */
  if (page === 'devices')
    return (
      <main className="app-shell">
        {header(t('devicesTitle'), 'settings')}
        {toastView}
        {feedback}
        <section className="page-pad stack-list">
          <Row
            title="Connected Devices"
            subtitle="Per-device policies, speed limits and quota controls"
            onClick={() => setPage('deviceList')}
            right={<Laptop size={18} color="var(--accent-cyan)" />}
          />
          <Row
            title="Guest Hotspot"
            subtitle="Create temporary auto-expiring guest Wi-Fi"
            onClick={() => setPage('guest')}
            right={<Wifi size={18} color="var(--accent-emerald)" />}
          />
          <ActionRow
            busy={busy}
            title="Hotspot Doctor"
            subtitle="Audit DNS, NAT, MSS, QUIC and conntrack parameters"
            onClick={() => {
              setPage('diagnostics');
              void helper(
                'hotspot-doctor',
                [],
                true,
                'Running Hotspot Doctor',
                'Inspecting hotspot protection…',
                'Doctor report generated.'
              );
            }}
            icon={<Activity size={18} color="var(--accent-cyan)" />}
          />
          <ActionRow
            busy={busy}
            title="Repair Hotspot Routing"
            subtitle="Re-apply IP forwarding and DNS redirection rules"
            onClick={() =>
              void helper(
                'hotspot-repair',
                [],
                false,
                'Repairing Hotspot',
                'Re-applying rules…',
                'Hotspot routing repaired.'
              )
            }
            icon={<RefreshCw size={18} color="var(--accent-emerald)" />}
          />
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: DEVICE LIST */
  if (page === 'deviceList') {
    const clients = router.hotspot?.clients || [];
    const opts = router.config || {};
    return (
      <main className="app-shell">
        {header(t('connectedDevices'), 'devices')}
        {toastView}
        {feedback}
        <section className="page-pad stack-list">
          <div className="quick-tools-bar">
            <button className="quick-tool-btn" disabled={busy} onClick={() => void loadRouter()}>
              <RefreshCw size={14} className={busy ? 'spin' : ''} />
              <span>Refresh ({clients.length} clients)</span>
            </button>
          </div>

          <span className="section-title">HOTSPOT SECURITY OPTIONS</span>
          <Row
            title="Force Protected DNS"
            subtitle="Keep clients on encrypted local resolver"
            onClick={() => void setRouterOptions({ force_dns: !opts.force_dns })}
            right={<Toggle on={!!opts.force_dns} label="Force DNS" />}
          />
          <Row
            title="Block QUIC Protocol"
            subtitle="Prevent UDP bypass and enforce TCP inspection"
            onClick={() => void setRouterOptions({ block_quic: !opts.block_quic })}
            right={<Toggle on={!!opts.block_quic} label="Block QUIC" />}
          />
          <Row
            title="Client Isolation"
            subtitle="Prevent hotspot clients from communicating with each other"
            onClick={() => void setRouterOptions({ client_isolation: !opts.client_isolation })}
            right={<Toggle on={!!opts.client_isolation} label="Client isolation" />}
          />

          <span className="section-title">CONNECTED CLIENTS</span>
          {clients.length === 0 ? (
            <div className="settings-row">
              <div className="settings-row-text">
                <b>No Active Clients</b>
                <small>Connect a client to the hotspot and click Refresh.</small>
              </div>
            </div>
          ) : (
            clients.map(cl => {
              const cfg = opts.devices?.[cl.mac] || {};
              const u = router.usage?.devices?.[cl.mac] || {};
              const draft = deviceDrafts[cl.mac] || { speed: '0', quota: '0' };
              return (
                <div key={cl.mac} className="settings-card">
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                      <Wifi size={16} color="var(--accent-cyan)" />
                      <b>{cl.ip}</b>
                    </div>
                    <span className={`ping-chip ${cfg.paused ? 'high' : 'good'}`}>
                      {cfg.paused ? 'PAUSED' : (cfg.policy || 'default').toUpperCase()}
                    </span>
                  </div>
                  <small>{cl.mac} · {cl.state}</small>
                  <div style={{ display: 'flex', gap: '10px', fontSize: '11px', color: 'var(--text-secondary)' }}>
                    <span>↓ {fmtBytes(u.day_down_bytes || 0)} today</span>
                    <span>↑ {fmtBytes(u.day_up_bytes || 0)} today</span>
                  </div>
                  <div className="quick-tools-bar">
                    {['default', 'vpn', 'direct', 'block'].map(p => (
                      <button
                        key={p}
                        className={`quick-tool-btn ${(cfg.policy || 'default') === p ? 'active' : ''}`}
                        onClick={() => void setDevice(cl.mac, p)}
                      >
                        {p}
                      </button>
                    ))}
                    <button
                      className="quick-tool-btn"
                      onClick={() => void setDevice(cl.mac, cfg.policy || 'default', !cfg.paused)}
                    >
                      {cfg.paused ? 'Resume' : 'Pause'}
                    </button>
                  </div>
                </div>
              );
            })
          )}
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );
  }

  /* PAGE: GUEST HOTSPOT */
  if (page === 'guest')
    return (
      <main className="app-shell">
        {header(t('guestHotspot'), 'devices')}
        {toastView}
        {feedback}
        <section className="page-pad stack-list">
          <div className="input-group">
            <label>Guest Network SSID</label>
            <input value={guestSsid} onChange={e => setGuestSsid(e.target.value)} />
          </div>
          <div className="input-group">
            <label>Auto-expiry Duration (Minutes)</label>
            <input
              value={guestMinutes}
              onChange={e => setGuestMinutes(e.target.value)}
              inputMode="numeric"
            />
          </div>
          <button
            className="connect-btn"
            disabled={busy}
            onClick={() =>
              void helper(
                'guest-start',
                [guestMinutes || '60', guestSsid || 'MilMit Guest'],
                false,
                'Starting Guest Hotspot',
                `Creating ${guestSsid}…`,
                'Guest hotspot active.'
              )
            }
          >
            Start Guest Hotspot
          </button>
          <button
            className="disconnect-btn"
            disabled={busy}
            onClick={() =>
              void helper(
                'guest-stop',
                [],
                false,
                'Stopping Guest Hotspot',
                'Disabling temporary network…',
                'Guest hotspot stopped.'
              )
            }
          >
            Stop Guest Hotspot
          </button>
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: USAGE */
  if (page === 'usage')
    return (
      <main className="app-shell">
        {header(t('usageTitle'), 'settings')}
        {toastView}
        <section className="page-pad stack-list">
          <TrafficChart
            history={trafficHistory}
            currentRx={traffic.rx_bps}
            currentTx={traffic.tx_bps}
          />

          <span className="section-title">DATA VOLUME COUNTERS</span>
          <div className="metrics-grid">
            <div className="metric-card">
              <span className="metric-header">
                <ArrowDown size={14} color="var(--accent-emerald)" /> Today Down
              </span>
              <b>{fmtBytes(usage.dayRx)}</b>
            </div>
            <div className="metric-card">
              <span className="metric-header">
                <ArrowUp size={14} color="var(--accent-cyan)" /> Today Up
              </span>
              <b>{fmtBytes(usage.dayTx)}</b>
            </div>
            <div className="metric-card">
              <span className="metric-header">
                <BarChart3 size={14} color="var(--accent-amber)" /> Today Total
              </span>
              <b>{fmtBytes(usage.dayRx + usage.dayTx)}</b>
            </div>
          </div>

          <div className="metrics-grid">
            <div className="metric-card">
              <span className="metric-header">This Month</span>
              <b>{fmtBytes(usage.monthRx + usage.monthTx)}</b>
            </div>
            <div className="metric-card">
              <span className="metric-header">All-Time</span>
              <b>{fmtBytes(usage.allRx + usage.allTx)}</b>
            </div>
            <div className="metric-card">
              <span className="metric-header">Status</span>
              <b style={{ color: conn.connected ? 'var(--accent-emerald)' : 'var(--text-secondary)' }}>
                {conn.connected ? 'Protected' : 'Direct'}
              </b>
            </div>
          </div>
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: ADVANCED */
  if (page === 'advanced')
    return (
      <main className="app-shell">
        {header(t('advancedTitle'), 'settings')}
        {toastView}
        {feedback}
        <section className="page-pad stack-list">
          <Row
            title="Custom Location Lists"
            subtitle={`${lists.length} custom server clusters`}
            onClick={() => setPage('customLists')}
            right={<ListPlus size={18} color="var(--accent-cyan)" />}
          />
          <Row
            title="Diagnostics & Verification"
            subtitle="Perform MTU, DNS leak and speed test benchmarks"
            onClick={() => setPage('diagnostics')}
            right={<Activity size={18} color="var(--accent-emerald)" />}
          />
          <ActionRow
            busy={busy}
            title="Support Diagnostics Bundle"
            subtitle="Export sanitized logs and system state report"
            onClick={() => {
              setPage('diagnostics');
              void helper(
                'support-bundle',
                [],
                true,
                'Generating Support Bundle',
                'Collecting sanitized logs…',
                'Support bundle generated.'
              );
            }}
            icon={<Server size={18} color="var(--accent-cyan)" />}
          />
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: CUSTOM LISTS */
  if (page === 'customLists')
    return (
      <main className="app-shell">
        {header(t('customLocationLists'), 'advanced')}
        {toastView}
        {feedback}
        <section className="page-pad stack-list">
          <div className="input-group">
            <label>New List Name</label>
            <div style={{ display: 'flex', gap: '8px' }}>
              <input
                value={newListName}
                onChange={e => setNewListName(e.target.value)}
                placeholder="e.g. Gaming Servers, Fast Europe…"
              />
              <button
                className="btn-primary"
                disabled={!newListName.trim()}
                onClick={() => void createList()}
              >
                <Plus size={16} /> Create
              </button>
            </div>
          </div>

          <div className="stack-list">
            {lists.map(list => (
              <div key={list.id} className="settings-card">
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <b>{list.name}</b>
                  <button className="icon-btn-close" onClick={() => void removeList(list.id)}>
                    <Trash2 size={16} />
                  </button>
                </div>
                <small>{list.location_ids.length} locations assigned</small>
                <button
                  className="quick-tool-btn"
                  onClick={() => void addSelectedToList(list.id)}
                >
                  Add currently selected ({selected.city})
                </button>
              </div>
            ))}
          </div>
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: DIAGNOSTICS */
  if (page === 'diagnostics')
    return (
      <main className="app-shell">
        {header(t('diagnosticsAndHealth'), 'advanced')}
        {toastView}
        {feedback}
        <section className="page-pad stack-list">
          <span className="section-title">LATENCY & PING PROBES</span>
          <div className="quick-tools-bar">
            <button className="quick-tool-btn" disabled={busy} onClick={() => void runPing('internet')}>
              Ping Internet
            </button>
            <button className="quick-tool-btn" disabled={busy} onClick={() => void runPing('vpn')}>
              Ping VPN
            </button>
            <button className="quick-tool-btn" disabled={busy} onClick={() => void runPing('location')}>
              Ping Server
            </button>
          </div>

          <span className="section-title">SECURITY BENCHMARKS</span>
          <div className="quick-tools-bar">
            <button
              className="quick-tool-btn"
              disabled={busy}
              onClick={() =>
                void helper(
                  'health',
                  [],
                  true,
                  'Health Audit',
                  'Checking tunnel integrity…',
                  'Health audit finished.'
                )
              }
            >
              Health Check
            </button>
            <button
              className="quick-tool-btn"
              disabled={busy}
              onClick={() =>
                void helper(
                  'speed-test',
                  [],
                  true,
                  'Speed Test',
                  'Measuring throughput…',
                  'Speed test finished.'
                )
              }
            >
              Speed Test
            </button>
            <button
              className="quick-tool-btn"
              disabled={busy}
              onClick={() =>
                void helper(
                  'dns-test',
                  [],
                  true,
                  'DNS Leak Test',
                  'Auditing resolver paths…',
                  'DNS leak check finished.'
                )
              }
            >
              DNS Test
            </button>
          </div>

          <div className="quick-tools-bar">
            <button
              className="quick-tool-btn"
              disabled={busy}
              onClick={() =>
                void helper(
                  'mtu-test',
                  [],
                  true,
                  'MTU/MSS Probing',
                  'Checking packet size…',
                  'MTU probe finished.'
                )
              }
            >
              MTU / MSS
            </button>
            <button
              className="quick-tool-btn"
              disabled={busy}
              onClick={() =>
                void helper(
                  'full-live-test',
                  [],
                  true,
                  'Live Verification',
                  'Verifying active data path…',
                  'Verification finished.'
                )
              }
            >
              Live Verify
            </button>
            <button
              className="quick-tool-btn"
              disabled={busy}
              onClick={() =>
                void helper(
                  'support-bundle',
                  [],
                  true,
                  'Creating Support Bundle',
                  'Collecting system data…',
                  'Support bundle generated.'
                )
              }
            >
              Support
            </button>
          </div>

          <span className="section-title">AI & WEBSITE ACCESS (CHATGPT & OPENAI)</span>
          <div className="quick-tools-bar">
            <button
              className="quick-tool-btn"
              disabled={busy || chatGptTesting}
              onClick={() => void runChatGptTest()}
            >
              <Bot size={15} style={{ marginRight: 4 }} />
              {chatGptTesting ? 'Testing ChatGPT…' : 'Test ChatGPT Access'}
            </button>
            <button
              className="quick-tool-btn"
              disabled={busy || dnsRepairing}
              onClick={() => void runDnsRepair()}
              style={{ borderColor: 'rgba(56, 189, 248, 0.4)', color: 'var(--accent-cyan)' }}
            >
              <RefreshCw size={15} className={dnsRepairing ? 'spin' : ''} style={{ marginRight: 4 }} />
              {dnsRepairing ? 'Repairing DNS…' : 'One-Click DNS Repair'}
            </button>
          </div>

          {chatGptResult && (
            <div className={`ai-diag-card ${chatGptResult.ok ? 'success' : 'warning'}`}>
              <div className="ai-diag-header">
                <span>ChatGPT Connectivity Probing</span>
                <b>
                  {chatGptResult.ok
                    ? '🟢 Unblocked & Reachable'
                    : chatGptResult.http_status === 403
                    ? '🟢 Cloudflare Verified (Unblocked)'
                    : '🔴 Blocked / Network Error'}
                </b>
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 4, marginTop: 4 }}>
                <div><b>Resolved IP(s):</b> {chatGptResult.resolved_ips && chatGptResult.resolved_ips.length > 0 ? chatGptResult.resolved_ips.join(', ') : 'None'}</div>
                <div><b>HTTP Response:</b> {chatGptResult.http_status || '—'} · <b>Latency:</b> {chatGptResult.latency_ms ? `${chatGptResult.latency_ms} ms` : '—'}</div>
                {chatGptResult.details && !chatGptResult.details.trim().startsWith('{') && (
                  <div style={{ color: 'var(--text-secondary)' }}><b>Diagnosis:</b> {chatGptResult.details}</div>
                )}
              </div>
            </div>
          )}

          <div className="credentials-note-box">
            <Shield size={20} />
            <div>
              <b>Why websites or ChatGPT may not open when connected:</b>
              <p style={{ margin: '4px 0 0 0' }}>
                Iranian ISPs often poison DNS queries in Ubuntu's local <code>systemd-resolved</code> cache before the VPN connects.
                If you encounter connection drops, Cloudflare blocks, or loading failures with ChatGPT, click <b>One-Click DNS Repair</b> to instantly flush polluted resolver caches and enforce secure Surfshark DNS across all network adapters.
              </p>
            </div>
          </div>

          <pre className="diagnostic-box">
            {busy ? 'Running diagnostic tests…' : diag || 'Select a test above to inspect live output.'}
          </pre>
        </section>
        <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
      </main>
    );

  /* PAGE: HOME (DASHBOARD) */
  const isConnecting = ['PREPARING', 'IKE', 'AUTHENTICATING', 'TUNNEL_ESTABLISHED', 'VERIFYING_DATA', 'FALLBACK', 'CONNECTING'].includes(phase);
  const isCancelling = phase === 'CANCELLING';
  const stateText = isCancelling
    ? t('cancelling')
    : isConnecting
    ? (phase === 'VERIFYING_DATA' ? t('verifying') : t('connecting'))
    : conn.connected
    ? t('connected')
    : t('disconnected');

  return (
    <main className={`app-shell ${conn.connected ? 'connected' : isConnecting ? 'connecting-mode' : ''}`}>
      {/* Top Bar */}
      <header className="topbar">
        <div className="brand">
          <div className={`brand-mark ${conn.connected ? 'pulse' : ''}`}>
            <Shield size={18} />
          </div>
          <span className="brand-title">{t('appTitle')}</span>
          <span className="brand-badge">IKEv2</span>
        </div>

        <div className="topbar-actions">
          <button
            className="lang-switch-btn"
            onClick={toggleLanguage}
            title={language === 'fa' ? 'Switch to English' : 'تغییر به زبان فارسی'}
            aria-label={t('language')}
          >
            <Globe size={15} />
            <span className="lang-switch-badge">{language.toUpperCase()}</span>
          </button>
          <button
            className={`icon-btn ${terminalOpen ? 'active' : ''}`}
            onClick={() => setTerminalOpen(!terminalOpen)}
            title={t('terminal')}
            aria-label="Terminal"
          >
            <Terminal size={18} />
          </button>
          <button
            className="icon-btn"
            onClick={() => setCredentialsOpen(true)}
            title={t('credentials')}
            aria-label="Credentials"
          >
            <Key size={18} />
          </button>
          <button
            className="icon-btn"
            onClick={() => setPage('settings')}
            title={t('settings')}
            aria-label="Settings"
          >
            <Settings size={18} />
          </button>
        </div>
      </header>

      {toastView}

      {/* Hero Status Area with Multi-State Animated Orb */}
      <section className="hero-area">
        <div
          className={`status-orb-wrap ${
            conn.connected ? 'connected' : isCancelling ? 'cancelling' : isConnecting ? 'working' : 'idle'
          }`}
          onClick={() => void toggleConnection()}
          title={conn.connected ? t('clickToDisconnect') : isConnecting ? t('clickToCancel') : t('clickToConnect')}
        >
          <div className="orb-ring" />
          <div className="orb-ring-inner" />
          <div className="status-orb">
            {isConnecting ? (
              <LoaderCircle size={52} className="spin" />
            ) : conn.connected ? (
              <ShieldCheck size={54} />
            ) : isCancelling ? (
              <ShieldAlert size={52} />
            ) : (
              <CirclePower size={52} />
            )}
          </div>
        </div>

        <h2>{stateText}</h2>
        <p>
          {conn.connected
            ? `${t('protectedVia')} ${selected.country} (${conn.public_ip || t('tunnelActive')})`
            : isConnecting
            ? t('establishingTunnel')
            : isCancelling
            ? t('revertingRoutes')
            : t('selectServerToSecure')}
        </p>

        {isConnecting && (
          <div className="phase-indicator-pill">
            <LoaderCircle size={14} className="spin" />
            <span>{phase.replace('_', ' ')}</span>
          </div>
        )}
      </section>

      {/* Main Actions */}
      <section className="home-actions">
        {/* Animated Visual Route Beam */}
        <RouteBeam
          connected={conn.connected}
          connecting={isConnecting}
          userIp={conn.public_ip}
          selectedCity={selected.city}
          selectedCountry={selected.country}
          selectedFlag={flagFor(selected.id)}
          ping={locations.find(x => x.id === selected.id)?.ping}
        />

        {/* Fastest Server Quick Action */}
        {!conn.connected && !isConnecting && (
          <div className="fastest-server-row">
            <button
              className="fastest-server-btn"
              disabled={busy || isConnecting || fastestConnecting}
              onClick={() => void autoConnectFastest()}
              title={t('fastestServerBtn')}
            >
              <Sparkles size={15} className={fastestConnecting ? 'spin' : ''} />
              <span>{fastestConnecting ? t('testingFastestNodes') : t('fastestServerBtn')}</span>
            </button>
          </div>
        )}

        {/* Server Selector Card */}
        <button className="location-card" onClick={() => setPage('locations')}>
          <span className="flag-badge">{flagFor(selected.id)}</span>
          <div className="loc-texts">
            <b>{selected.country}</b>
            <small>{selected.city} · {selected.host}</small>
          </div>
          <span className={`ping-chip ${typeof selected.ping === 'number' ? (selected.ping < 100 ? 'good' : 'medium') : ''}`}>
            <span className="ping-dot" />
            {pingLabel(locations.find(x => x.id === selected.id)?.ping)}
          </span>
          <ChevronRight size={18} color="var(--text-secondary)" />
        </button>

        {/* Main Connect / Disconnect / Cancel Button */}
        {isConnecting ? (
          <button
            className="cancel-btn"
            onClick={() => void cancelInFlightConnection()}
          >
            <X size={18} />
            <span>{t('cancelBtn')}</span>
          </button>
        ) : conn.connected ? (
          <button
            disabled={busy || !!phase}
            className="disconnect-btn"
            onClick={() => void toggleConnection()}
          >
            <CirclePower size={18} />
            <span>{t('disconnectBtn')}</span>
          </button>
        ) : (
          <button
            disabled={busy || !!phase}
            className="connect-btn"
            onClick={() => void toggleConnection()}
          >
            <Zap size={18} />
            <span>{t('secureMyConnection')}</span>
          </button>
        )}

        {/* Live Traffic Waveform Chart */}
        <div onClick={() => setPage('usage')} style={{ cursor: 'pointer' }}>
          <TrafficChart
            history={trafficHistory}
            currentRx={traffic.rx_bps}
            currentTx={traffic.tx_bps}
          />
        </div>

        {/* Network Status HUD Card */}
        <div className="network-hud-card">
          <div className="hud-item">
            <span className={`hud-indicator ${conn.connected ? 'online' : 'lockdown-off'}`} />
            <div className="hud-meta">
              <span className="hud-title">{t('international')}</span>
              <span className="hud-value">
                {conn.connected ? `${conn.exit_country || 'Global'} (${conn.latency_ms || '~'}${t('ms')})` : t('directStandby')}
              </span>
            </div>
          </div>
          <div className="hud-item">
            <span className="hud-indicator iran" />
            <div className="hud-meta">
              <span className="hud-title">{t('iranBypass')}</span>
              <span className="hud-value">
                {routingMode?.routing_mode === 'iran_direct' ? t('bypassedOn') : t('fullTunnel')}
              </span>
            </div>
          </div>
          <div className="hud-item">
            <span className={`hud-indicator ${desktopFeatures.lockdown ? 'lockdown-active' : 'lockdown-off'}`} />
            <div className="hud-meta">
              <span className="hud-title">{t('killSwitch')}</span>
              <button
                className="hud-toggle-link"
                onClick={() => void setDesktopFlag('lockdown', !desktopFeatures.lockdown)}
                title={t('killSwitchToggleHint')}
              >
                {desktopFeatures.lockdown ? t('armedOn') : t('disabled')}
              </button>
            </div>
          </div>
        </div>

        {/* Metrics Grid */}
        <div className="metrics-grid">
          <div className="metric-card">
            <span className="metric-header">
              <Gauge size={13} color="var(--accent-cyan)" /> {t('latency')}
            </span>
            <b>{conn.latency_ms ? `${conn.latency_ms} ${t('ms')}` : pingLabel(locations.find(x => x.id === selected.id)?.ping)}</b>
          </div>
          <div className="metric-card">
            <span className="metric-header">
              <Shield size={13} color="var(--accent-emerald)" /> {t('publicIp')}
            </span>
            <b>{conn.public_ip || '—'}</b>
          </div>
          <div className="metric-card">
            <span className="metric-header">
              <MapPin size={13} color="var(--accent-amber)" /> {t('exitNode')}
            </span>
            <b>{conn.exit_country || selected.country || '—'}</b>
          </div>
        </div>

        {/* Quick Tools */}
        <div className="quick-tools-bar">
          <button className="quick-tool-btn" onClick={() => void smartQuickConnect()}>
            <Zap size={14} color="var(--accent-emerald)" />
            <span>{t('smartConnect')}</span>
          </button>
          <button className="quick-tool-btn" onClick={() => void scanAll(false)} disabled={scanning}>
            <RefreshCw size={14} className={scanning ? 'spin' : ''} />
            <span>{scanning ? t('probing') : t('pingServers')}</span>
          </button>
          <button className="quick-tool-btn" onClick={() => setPage('split')}>
            <Laptop size={14} color="var(--accent-cyan)" />
            <span>{t('splitApps')}</span>
          </button>
        </div>
      </section>

      {/* Modals */}
      <CredentialsModal
        isOpen={credentialsOpen}
        onClose={() => setCredentialsOpen(false)}
        onSuccess={msg => setToast(msg)}
      />
      <LogTerminal isOpen={terminalOpen} onClose={() => setTerminalOpen(false)} />
    </main>
  );
}

createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <LanguageProvider>
      <App />
    </LanguageProvider>
  </React.StrictMode>
);
