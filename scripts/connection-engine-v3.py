#!/usr/bin/env python3
import ipaddress, json, os, pathlib, re, signal, subprocess, sys, tempfile, time
from datetime import datetime, timezone

RUN = pathlib.Path('/run/milmit-surfshark')
VAR = pathlib.Path('/var/lib/milmit-surfshark')
ETC = pathlib.Path('/etc/milmit-surfshark')
STATE = RUN / 'engine-v3.json'
EVENTS = RUN / 'engine-v3.events'
HEALTH = VAR / 'endpoint-health.json'
ENDPOINT_CACHE = VAR / 'endpoint-cache.json'
LKG = VAR / 'lkg-v3.json'
CRED = ETC / 'credentials'
LEGACY_STATE = RUN / 'restricted.state'
CONNECT = '/usr/lib/milmit-surfshark/restricted-ikev2-connect-v2.sh'
DISCONNECT = '/usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh'
IKE_NAME = 'milmit-surfshark-restricted'
WG_DIR = ETC / 'wireguard'
OVPN_DIR = ETC / 'openvpn'
OPENVPN_PID = RUN / 'openvpn.pid'
WG_ACTIVE = RUN / 'wireguard-active'
PHASES = ('IDLE','PREPARING','DISCOVERING','IKE','AUTHENTICATING','TUNNEL_ESTABLISHED','VERIFYING_DATA','FALLBACK','CONNECTED','BLOCKED','FAILED','CANCELLING','DISCONNECTED')

# DNS-over-HTTPS providers are pinned to public resolver IPs with --resolve, so the local
# resolver can be poisoned without affecting endpoint discovery. TLS still validates the
# provider hostname; we intentionally do not use curl -k here.
DOH_PROVIDERS = (
    ('cloudflare', 'cloudflare-dns.com', '1.1.1.1', '/dns-query'),
    ('cloudflare-secondary', 'cloudflare-dns.com', '1.0.0.1', '/dns-query'),
    ('google', 'dns.google', '8.8.8.8', '/resolve'),
    ('google-secondary', 'dns.google', '8.8.4.4', '/resolve'),
)
CACHE_MAX_AGE = 48 * 60 * 60

RUN.mkdir(parents=True, exist_ok=True)
VAR.mkdir(parents=True, exist_ok=True)


def now(): return datetime.now(timezone.utc).isoformat()
def unix_now(): return int(time.time())
def atomic_json(path, obj, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=2))
    os.chmod(tmp, mode); tmp.replace(path)
def load_json(path, default):
    try: return json.loads(path.read_text())
    except Exception: return default
def emit(phase, message, **extra):
    if phase not in PHASES: phase = 'FAILED'
    row = {'time': now(), 'phase': phase, 'message': message, **extra}
    with EVENTS.open('a') as f: f.write(json.dumps(row, ensure_ascii=False) + '\n')
    st = load_json(STATE, {})
    st.update({'phase': phase, 'message': message, 'updated_at': row['time'], **extra})
    atomic_json(STATE, st)
    print(f"ENGINE phase={phase} message={message}", flush=True)
    return row

def read_kv(path):
    out = {}
    try:
        for line in path.read_text(errors='replace').splitlines():
            if '=' in line:
                k,v = line.split('=',1); out[k] = v
    except OSError: pass
    return out

def credentials():
    if not CRED.exists(): raise RuntimeError('Saved Surfshark credentials are unavailable.')
    script = 'set -a; source "$1"; printf "%s\\n%s" "$SERVICE_USER" "$SERVICE_PASS"'
    p = subprocess.run(['/bin/bash','-c',script,'bash',str(CRED)], text=True, capture_output=True, timeout=4)
    if p.returncode: raise RuntimeError('Could not read saved Surfshark credentials.')
    parts = p.stdout.split('\n',1)
    if len(parts) != 2 or not all(parts): raise RuntimeError('Saved Surfshark credentials are incomplete.')
    return parts[0], parts[1]

def proc(args, timeout=12, env=None, input_text=None):
    try:
        p = subprocess.run(args, text=True, input=input_text, capture_output=True, timeout=timeout, env=env)
        text = p.stdout + ('\n' if p.stdout and p.stderr else '') + p.stderr
        return p.returncode, text.strip()
    except subprocess.TimeoutExpired as e:
        text = ((e.stdout or '') if isinstance(e.stdout,str) else '') + ((e.stderr or '') if isinstance(e.stderr,str) else '')
        return 124, text.strip()

def valid_public_ipv4(value):
    try:
        ip = ipaddress.ip_address(str(value))
        return ip.version == 4 and not (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified)
    except ValueError:
        return False

def unique(values):
    out=[]
    for value in values:
        value=str(value).strip()
        if valid_public_ipv4(value) and value not in out: out.append(value)
    return out

def parse_doh_answers(text):
    try: data=json.loads(text)
    except Exception: return []
    answers=[]
    for row in data.get('Answer') or []:
        if int(row.get('type',0)) == 1 and valid_public_ipv4(row.get('data','')):
            answers.append(str(row['data']).strip())
    return unique(answers)

def secure_doh_a(identity):
    if not re.fullmatch(r'[A-Za-z0-9.-]+\.prod\.surfshark\.com', identity): return [], []
    found=[]; sources=[]
    for source, hostname, ip, path in DOH_PROVIDERS:
        url=f'https://{hostname}{path}?name={identity}&type=A'
        rc,text=proc([
            'curl','-4','-fsS','--connect-timeout','2','--max-time','3',
            '--resolve',f'{hostname}:443:{ip}',
            '-H','accept: application/dns-json',url
        ],4)
        if rc != 0: continue
        answers=parse_doh_answers(text)
        if answers:
            sources.append(source)
            for addr in answers:
                if addr not in found: found.append(addr)
        # Two independent successful providers are enough; keep discovery fast.
        if len(sources) >= 2: break
    return found, sources

def cached_discovered(identity):
    data=load_json(ENDPOINT_CACHE,{'locations':{}})
    row=(data.get('locations') or {}).get(identity) or {}
    try: updated=int(row.get('updated_unix',0))
    except Exception: updated=0
    if unix_now()-updated > CACHE_MAX_AGE: return []
    return unique(row.get('addresses') or [])

def cache_discovered(identity, addresses, sources):
    if not addresses: return
    data=load_json(ENDPOINT_CACHE,{'locations':{}}); locations=data.setdefault('locations',{})
    previous=locations.get(identity) or {}
    merged=unique(addresses + list(previous.get('addresses') or []))[:32]
    locations[identity]={
        'addresses': merged,
        'sources': list(dict.fromkeys(sources)),
        'updated_at': now(),
        'updated_unix': unix_now(),
    }
    atomic_json(ENDPOINT_CACHE,data,0o600)

def learned_successes(identity):
    eps=(load_json(HEALTH,{'endpoints':{}}).get('endpoints') or {})
    rows=[]
    prefix=f'ikev2:{identity}:'
    for key,row in eps.items():
        if not key.startswith(prefix): continue
        endpoint=str(row.get('endpoint') or key[len(prefix):])
        if not valid_public_ipv4(endpoint): continue
        if int(row.get('successes',0) or 0) <= 0: continue
        rows.append((str(row.get('last_success') or ''), endpoint))
    rows.sort(reverse=True)
    return unique([x[1] for x in rows])

def discover_candidates(identity, bundled):
    lkg=load_json(LKG,{})
    lkg_ip=[]
    if lkg.get('identity')==identity and lkg.get('protocol')=='ikev2' and valid_public_ipv4(lkg.get('endpoint','')):
        lkg_ip=[str(lkg['endpoint'])]

    emit('DISCOVERING','Refreshing current Surfshark endpoint addresses',identity=identity)
    fresh,sources=secure_doh_a(identity)
    if fresh:
        cache_discovered(identity,fresh,sources)
        emit('DISCOVERING','Secure DNS returned fresh endpoint addresses',identity=identity,discovered=fresh,sources=sources)
    else:
        emit('DISCOVERING','Secure DNS refresh unavailable; using learned/cache/bootstrap candidates',identity=identity)

    cached=cached_discovered(identity)
    learned=learned_successes(identity)
    # Priority: LKG -> fresh secure DNS -> recent cached discovery -> previously successful -> bundled bootstrap.
    merged=unique(lkg_ip + fresh + cached + learned + list(bundled))[:32]
    source_summary={
        'lkg': lkg_ip,
        'fresh': fresh,
        'cached': cached,
        'learned': learned,
        'bootstrap': unique(bundled),
    }
    emit('DISCOVERING','Endpoint pool ready',identity=identity,candidates=merged,candidate_sources=source_summary)
    return merged

def cleanup_protocols():
    if OPENVPN_PID.exists():
        try:
            pid = int(OPENVPN_PID.read_text().strip()); os.kill(pid, signal.SIGTERM); time.sleep(0.15)
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        except Exception: pass
        OPENVPN_PID.unlink(missing_ok=True)
    if WG_ACTIVE.exists():
        try:
            conf = WG_ACTIVE.read_text().strip()
            if conf: proc(['wg-quick','down',conf], 12)
        except Exception: pass
        WG_ACTIVE.unlink(missing_ok=True)
    proc(['swanctl','--terminate','--ike',IKE_NAME], 6)

def classify_ike(text, rc):
    low = text.lower()
    established = ('ike_sa milmit-surfshark-restricted' in low and 'established' in low) or 'initiate completed successfully' in low
    child = 'child_sa milmit-restricted' in low and 'established' in low
    no_rx = 'no decrypted return traffic' in low or 'data path remains unusable' in low
    auth_failed = 'authentication failed' in low or 'eap authentication failed' in low
    timeout = rc == 124 or 'timed out' in low
    if established and child and no_rx: return 'DATA_PATH_BLOCKED'
    if established and child and rc == 0: return 'CONNECTED'
    if auth_failed: return 'AUTH_FAILED'
    if timeout: return 'TIMEOUT'
    if established and child: return 'POST_TUNNEL_FAILED'
    return 'HANDSHAKE_FAILED'

def health_update(identity, endpoint, outcome, latency=None, protocol='ikev2'):
    data = load_json(HEALTH, {'endpoints':{}}); eps=data.setdefault('endpoints',{})
    key=f'{protocol}:{identity}:{endpoint}'; row=eps.setdefault(key, {'successes':0,'failures':0})
    row['last_outcome']=outcome; row['updated_at']=now(); row['protocol']=protocol; row['identity']=identity; row['endpoint']=endpoint
    if outcome == 'CONNECTED': row['successes']=int(row.get('successes',0))+1; row['last_success']=now()
    else: row['failures']=int(row.get('failures',0))+1; row['last_failure']=now()
    if latency is not None: row['latency_ms']=latency
    atomic_json(HEALTH,data,0o600)

def ordered_candidates(identity, candidates):
    data=load_json(HEALTH,{'endpoints':{}}).get('endpoints',{})
    lkg=load_json(LKG,{})
    base_order={ip:i for i,ip in enumerate(candidates)}
    def score(ip):
        row=data.get(f'ikev2:{identity}:{ip}',{})
        s=int(row.get('successes',0))*20-int(row.get('failures',0))*6
        if row.get('last_outcome')=='DATA_PATH_BLOCKED': s-=35
        if row.get('last_outcome') in ('TIMEOUT','HANDSHAKE_FAILED'): s-=12
        if lkg.get('identity')==identity and lkg.get('endpoint')==ip and lkg.get('protocol')=='ikev2': s+=1000
        # Preserve discovery priority when health scores are equal.
        return (-s, base_order.get(ip,999))
    return sorted(dict.fromkeys(candidates), key=score)

def write_lkg(protocol, identity, endpoint, tunnel_if=''):
    atomic_json(LKG, {'protocol':protocol,'identity':identity,'endpoint':endpoint,'tunnel_if':tunnel_if,'saved_at':now()},0o600)

def ike_try(endpoint, identity, opts):
    user,_ = credentials()
    args=[CONNECT, endpoint, user, opts['mss'], opts['dns'], opts['hotspot'], opts['recover'], opts['hotspot_iface'], opts['kill'], opts['mode'], opts['vpn_macs'], opts['direct_macs'], identity]
    emit('IKE','Starting direct-IP IKEv2 handshake',protocol='ikev2',endpoint=endpoint,identity=identity)
    started=time.monotonic()
    rc,text=proc(args, timeout=int(opts.get('ike_timeout','34')))
    latency=max(1,int((time.monotonic()-started)*1000))
    outcome=classify_ike(text,rc)
    if 'eap-ms-chapv2 succeeded' in text.lower(): emit('AUTHENTICATING','EAP authentication succeeded',protocol='ikev2',endpoint=endpoint)
    if 'child_sa milmit-restricted' in text.lower() and 'established' in text.lower(): emit('TUNNEL_ESTABLISHED','IKE and CHILD SAs established',protocol='ikev2',endpoint=endpoint)
    emit('VERIFYING_DATA',f'IKEv2 result: {outcome}',protocol='ikev2',endpoint=endpoint,outcome=outcome)
    health_update(identity,endpoint,outcome,latency=latency if outcome=='CONNECTED' else None,protocol='ikev2')
    return outcome,text

def verify_generic(tunnel_if=None):
    before=''
    if tunnel_if: before=read_kv(LEGACY_STATE).get('PUBLIC_IP','')
    for url in ('https://1.1.1.1/cdn-cgi/trace','https://1.0.0.1/cdn-cgi/trace'):
        rc,text=proc(['curl','-4','-ksS','--connect-timeout','4','--max-time','7',url],9)
        if rc==0:
            m=re.search(r'^ip=(.+)$',text,re.M); loc=re.search(r'^loc=(.+)$',text,re.M)
            if m: return True,m.group(1).strip(),loc.group(1).strip() if loc else ''
    return False,before,''

def wireguard_try(identity):
    conf=WG_DIR/(identity+'.conf')
    if not conf.exists() or not shutil_which('wg-quick'): return None,'WireGuard profile unavailable'
    emit('FALLBACK','Trying WireGuard fallback',protocol='wireguard',identity=identity)
    proc(['wg-quick','down',str(conf)],10)
    rc,text=proc(['wg-quick','up',str(conf)],20)
    if rc: return False,text
    WG_ACTIVE.write_text(str(conf))
    ok,ip,country=verify_generic()
    if ok:
        write_lkg('wireguard',identity,str(conf),'wg')
        return True,f'WireGuard verified public_ip={ip} country={country}'
    proc(['wg-quick','down',str(conf)],12); WG_ACTIVE.unlink(missing_ok=True)
    return False,'WireGuard tunnel started but data verification failed.'

def openvpn_try(identity):
    conf=OVPN_DIR/(identity+'.ovpn')
    if not conf.exists() or not shutil_which('openvpn'): return None,'OpenVPN profile unavailable'
    emit('FALLBACK','Trying OpenVPN fallback',protocol='openvpn',identity=identity)
    user,pw=credentials()
    fd,path=tempfile.mkstemp(prefix='milmit-ovpn-auth-',dir=str(RUN),text=True)
    try:
        os.write(fd,(user+'\n'+pw+'\n').encode()); os.close(fd); os.chmod(path,0o600)
        log=RUN/'openvpn.log'; OPENVPN_PID.unlink(missing_ok=True)
        args=['openvpn','--config',str(conf),'--auth-user-pass',path,'--auth-nocache','--daemon','milmit-openvpn','--writepid',str(OPENVPN_PID),'--log',str(log)]
        rc,text=proc(args,12)
        if rc: return False,text
        for _ in range(16):
            time.sleep(0.5)
            if log.exists() and 'Initialization Sequence Completed' in log.read_text(errors='replace'):
                ok,ip,country=verify_generic()
                if ok:
                    write_lkg('openvpn',identity,str(conf),'tun')
                    return True,f'OpenVPN verified public_ip={ip} country={country}'
                break
        cleanup_protocols(); return False,'OpenVPN started but data verification failed.'
    finally:
        try: os.unlink(path)
        except OSError: pass

def shutil_which(name):
    from shutil import which
    return which(name)

def connect(identity, candidates, opts):
    EVENTS.write_text(''); os.chmod(EVENTS,0o600)
    atomic_json(STATE, {'phase':'PREPARING','identity':identity,'protocol':'','started_at':now(),'cancelled':False},0o644)
    emit('PREPARING','Connection engine v3 started',identity=identity,candidates=candidates)
    cleanup_protocols()
    candidates=discover_candidates(identity,candidates)
    if not candidates:
        emit('FAILED','No usable endpoint address could be discovered.',identity=identity)
        return 69
    blocked=0; attempted=0
    for endpoint in ordered_candidates(identity,candidates):
        attempted+=1
        outcome,text=ike_try(endpoint,identity,opts)
        safe='\n'.join(text.splitlines()[-80:])
        print(f'ENGINE_BACKEND endpoint={endpoint} outcome={outcome}\n{safe}',flush=True)
        if outcome=='CONNECTED':
            write_lkg('ikev2',identity,endpoint,'milmitxfrm0')
            # A successful endpoint is immediately learned even if it came from fresh DNS.
            cache_discovered(identity,[endpoint],['successful-connect'])
            emit('CONNECTED','VPN connected and data path verified',protocol='ikev2',endpoint=endpoint,identity=identity)
            return 0
        if outcome=='AUTH_FAILED':
            emit('FAILED','Authentication failed; stopping retries',protocol='ikev2',endpoint=endpoint)
            return 66
        if outcome=='DATA_PATH_BLOCKED': blocked+=1
        cleanup_protocols(); time.sleep(0.2)
    emit('FALLBACK','IKEv2 candidates exhausted; checking fallback transports',identity=identity,ike_blocked=blocked,ike_attempted=attempted)
    for name,fn in (('wireguard',wireguard_try),('openvpn',openvpn_try)):
        res,detail=fn(identity)
        if res is True:
            emit('CONNECTED',f'Connected using {name} fallback',protocol=name,identity=identity,detail=detail)
            return 0
        if res is False: emit('FALLBACK',f'{name} fallback failed',protocol=name,detail=detail)
        else: emit('FALLBACK',f'{name} fallback not configured',protocol=name,detail=detail)
    if attempted and blocked==attempted:
        emit('BLOCKED','IKEv2 control channel works but encrypted data path is blocked on this network; no configured fallback profile succeeded.',identity=identity,blocked_candidates=blocked)
        return 68
    emit('FAILED','No connection candidate or configured fallback transport succeeded.',identity=identity)
    return 69

def disconnect(reason='manual'):
    emit('CANCELLING' if reason=='cancel' else 'DISCONNECTED',f'Stopping active connection ({reason})')
    cleanup_protocols()
    env=os.environ.copy(); env['MILMIT_DISCONNECT_REASON']=reason
    proc([DISCONNECT],15,env=env)
    emit('DISCONNECTED','Connection state cleared',reason=reason)
    return 0

def status():
    st=load_json(STATE, {'phase':'IDLE','message':'No engine session yet'})
    st['endpoint_health']=load_json(HEALTH,{'endpoints':{}})
    st['endpoint_cache']=load_json(ENDPOINT_CACHE,{'locations':{}})
    st['last_known_good']=load_json(LKG,{})
    st['fallback']={
        'wireguard': {'available': bool(shutil_which('wg-quick')), 'profiles': sorted(p.stem for p in WG_DIR.glob('*.conf')) if WG_DIR.exists() else []},
        'openvpn': {'available': bool(shutil_which('openvpn')), 'profiles': sorted(p.stem for p in OVPN_DIR.glob('*.ovpn')) if OVPN_DIR.exists() else []},
    }
    print(json.dumps(st,ensure_ascii=False))
    return 0

def discover_only(identity, bundled):
    found=discover_candidates(identity,bundled)
    print(json.dumps({'identity':identity,'candidates':found,'cache':load_json(ENDPOINT_CACHE,{'locations':{}}).get('locations',{}).get(identity,{})},ensure_ascii=False))
    return 0 if found else 69

def main():
    if os.geteuid()!=0: print('engine v3 must run as root',file=sys.stderr); return 77
    cmd=sys.argv[1] if len(sys.argv)>1 else 'status'
    if cmd=='status': return status()
    if cmd in ('cancel','disconnect'): return disconnect('cancel' if cmd=='cancel' else 'manual')
    if cmd in ('connect','discover'):
        min_args=5 if cmd=='connect' else 4
        if len(sys.argv)<min_args:
            print(f'usage: connection-engine-v3.py {cmd} IDENTITY CANDIDATES_JSON' + (' OPTIONS_JSON' if cmd=='connect' else ''),file=sys.stderr); return 64
        identity=sys.argv[2]
        if not re.fullmatch(r'[A-Za-z0-9.-]+\.prod\.surfshark\.com',identity): return 64
        try: candidates=json.loads(sys.argv[3])
        except Exception: return 64
        if not isinstance(candidates,list) or not candidates or len(candidates)>32: return 64
        if any(not valid_public_ipv4(x) for x in candidates): return 64
        candidates=[str(x) for x in candidates]
        if cmd=='discover': return discover_only(identity,candidates)
        try: opts=json.loads(sys.argv[4])
        except Exception: return 64
        return connect(identity,candidates,opts)
    print('unsupported engine command',file=sys.stderr); return 64

if __name__=='__main__': raise SystemExit(main())