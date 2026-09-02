#!/usr/bin/env python3
import json, os, pathlib, re, shlex, signal, subprocess, sys, tempfile, time
from datetime import datetime, timezone

RUN = pathlib.Path('/run/milmit-surfshark')
VAR = pathlib.Path('/var/lib/milmit-surfshark')
ETC = pathlib.Path('/etc/milmit-surfshark')
STATE = RUN / 'engine-v3.json'
EVENTS = RUN / 'engine-v3.events'
HEALTH = VAR / 'endpoint-health.json'
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
PHASES = ('IDLE','PREPARING','IKE','AUTHENTICATING','TUNNEL_ESTABLISHED','VERIFYING_DATA','FALLBACK','CONNECTED','BLOCKED','FAILED','CANCELLING','DISCONNECTED')

RUN.mkdir(parents=True, exist_ok=True)
VAR.mkdir(parents=True, exist_ok=True)


def now(): return datetime.now(timezone.utc).isoformat()
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
    vals = read_kv(CRED)
    # credentials file uses shell escaping; parse through a non-executing shell printf.
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

def cleanup_protocols():
    # OpenVPN fallback
    if OPENVPN_PID.exists():
        try:
            pid = int(OPENVPN_PID.read_text().strip()); os.kill(pid, signal.SIGTERM); time.sleep(0.15)
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        except Exception: pass
        OPENVPN_PID.unlink(missing_ok=True)
    # WireGuard fallback
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
    def score(ip):
        row=data.get(f'ikev2:{identity}:{ip}',{})
        s=int(row.get('successes',0))*20-int(row.get('failures',0))*5
        if row.get('last_outcome')=='DATA_PATH_BLOCKED': s-=20
        if lkg.get('identity')==identity and lkg.get('endpoint')==ip and lkg.get('protocol')=='ikev2': s+=1000
        return -s
    return sorted(dict.fromkeys(candidates), key=score)

def write_lkg(protocol, identity, endpoint, tunnel_if=''):
    atomic_json(LKG, {'protocol':protocol,'identity':identity,'endpoint':endpoint,'tunnel_if':tunnel_if,'saved_at':now()},0o600)

def ike_try(endpoint, identity, opts):
    user,_ = credentials()
    args=[CONNECT, endpoint, user, opts['mss'], opts['dns'], opts['hotspot'], opts['recover'], opts['hotspot_iface'], opts['kill'], opts['mode'], opts['vpn_macs'], opts['direct_macs'], identity]
    emit('IKE','Starting direct-IP IKEv2 handshake',protocol='ikev2',endpoint=endpoint,identity=identity)
    rc,text=proc(args, timeout=int(opts.get('ike_timeout','34')))
    # The connector never receives the password on argv; it loads the root-only credential file when stdin is empty.
    outcome=classify_ike(text,rc)
    if 'eap-ms-chapv2 succeeded' in text.lower(): emit('AUTHENTICATING','EAP authentication succeeded',protocol='ikev2',endpoint=endpoint)
    if 'child_sa milmit-restricted' in text.lower() and 'established' in text.lower(): emit('TUNNEL_ESTABLISHED','IKE and CHILD SAs established',protocol='ikev2',endpoint=endpoint)
    emit('VERIFYING_DATA',f'IKEv2 result: {outcome}',protocol='ikev2',endpoint=endpoint,outcome=outcome)
    health_update(identity,endpoint,outcome,protocol='ikev2')
    return outcome,text

def verify_generic(tunnel_if=None):
    before=''
    if tunnel_if:
        before=read_kv(LEGACY_STATE).get('PUBLIC_IP','')
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
    blocked=0; attempted=0
    for endpoint in ordered_candidates(identity,candidates):
        attempted+=1
        outcome,text=ike_try(endpoint,identity,opts)
        # Keep output concise but useful for the UI log.
        safe='\n'.join(text.splitlines()[-80:])
        print(f'ENGINE_BACKEND endpoint={endpoint} outcome={outcome}\n{safe}',flush=True)
        if outcome=='CONNECTED':
            write_lkg('ikev2',identity,endpoint,'milmitxfrm0')
            emit('CONNECTED','VPN connected and data path verified',protocol='ikev2',endpoint=endpoint,identity=identity)
            return 0
        if outcome=='AUTH_FAILED':
            emit('FAILED','Authentication failed; stopping retries',protocol='ikev2',endpoint=endpoint)
            return 66
        if outcome=='DATA_PATH_BLOCKED': blocked+=1
        cleanup_protocols(); time.sleep(0.2)
    # Protocol fallback is automatic when a matching manual profile is installed.
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
    st['last_known_good']=load_json(LKG,{})
    st['fallback']={
        'wireguard': {'available': bool(shutil_which('wg-quick')), 'profiles': sorted(p.stem for p in WG_DIR.glob('*.conf')) if WG_DIR.exists() else []},
        'openvpn': {'available': bool(shutil_which('openvpn')), 'profiles': sorted(p.stem for p in OVPN_DIR.glob('*.ovpn')) if OVPN_DIR.exists() else []},
    }
    print(json.dumps(st,ensure_ascii=False))
    return 0

def main():
    if os.geteuid()!=0: print('engine v3 must run as root',file=sys.stderr); return 77
    cmd=sys.argv[1] if len(sys.argv)>1 else 'status'
    if cmd=='status': return status()
    if cmd in ('cancel','disconnect'): return disconnect('cancel' if cmd=='cancel' else 'manual')
    if cmd=='connect':
        if len(sys.argv)<5: print('usage: connection-engine-v3.py connect IDENTITY CANDIDATES_JSON OPTIONS_JSON',file=sys.stderr); return 64
        identity=sys.argv[2]
        if not re.fullmatch(r'[A-Za-z0-9.-]+',identity): return 64
        try:
            candidates=json.loads(sys.argv[3]); opts=json.loads(sys.argv[4])
        except Exception: return 64
        if not isinstance(candidates,list) or not candidates or len(candidates)>32: return 64
        if any(not re.fullmatch(r'(?:\d{1,3}\.){3}\d{1,3}',str(x)) for x in candidates): return 64
        return connect(identity,[str(x) for x in candidates],opts)
    print('unsupported engine command',file=sys.stderr); return 64

if __name__=='__main__': raise SystemExit(main())
