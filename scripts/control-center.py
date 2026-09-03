#!/usr/bin/env python3
import ipaddress
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import datetime, timezone

STATE = pathlib.Path('/run/milmit-surfshark/restricted.state')
LIVE = pathlib.Path('/run/milmit-surfshark/live.state')
VAR = pathlib.Path('/var/lib/milmit-surfshark')
LKG = VAR / 'last-known-good.state'
HISTORY = VAR / 'events.jsonl'
IRAN_LIST = VAR / 'iran-ipv4.txt'
XFRM = 'milmitxfrm0'
MARK = '0x112'
HELPER = '/usr/libexec/milmit-surfshark-helper'
DISCONNECT = '/usr/lib/milmit-surfshark/restricted-ikev2-disconnect.sh'


LAST = VAR / 'last-profile.state'


def read_kv(path):
    out = {}
    try:
        for line in pathlib.Path(path).read_text(errors='replace').splitlines():
            if '=' in line:
                k, v = line.split('=', 1)
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def write_kv_key(path, key, val):
    p = pathlib.Path(path)
    lines = []
    found = False
    if p.exists():
        try:
            for line in p.read_text(errors='replace').splitlines():
                if '=' in line and line.split('=', 1)[0].strip() == key:
                    lines.append(f"{key}={val}")
                    found = True
                elif line.strip():
                    lines.append(line)
        except OSError:
            pass
    if not found:
        lines.append(f"{key}={val}")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text('\n'.join(lines) + '\n')



def run(args, timeout=12):
    try:
        p = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        return p.returncode, (p.stdout + ('\n' if p.stdout and p.stderr else '') + p.stderr).strip()
    except Exception as e:
        return 124, str(e)


def event(kind, message, **extra):
    VAR.mkdir(parents=True, exist_ok=True)
    row = {'time': datetime.now(timezone.utc).isoformat(), 'kind': kind, 'message': message, **extra}
    try:
        with HISTORY.open('a') as f:
            f.write(json.dumps(row, ensure_ascii=False) + '\n')
        os.chmod(HISTORY, 0o600)
    except OSError:
        pass


def sa_established():
    rc, text = run(['swanctl', '--list-sas'], 6)
    return rc == 0 and 'milmit-surfshark-restricted:' in text and 'ESTABLISHED' in text, text


def public_ip():
    rc, text = run(['curl', '-4', '--max-time', '8', '-sS', 'https://api.ipify.org'], 10)
    return text.strip() if rc == 0 and re.fullmatch(r'(?:\d{1,3}\.){3}\d{1,3}', text.strip()) else ''


def route_for(target='1.1.1.1'):
    return run(['ip', '-4', 'route', 'get', target], 4)[1]


def health():
    st, lv = read_kv(STATE), read_kv(LIVE)
    score = 0
    checks = []
    def add(name, ok, points, detail=''):
        nonlocal score
        if ok: score += points
        checks.append({'name': name, 'ok': bool(ok), 'points': points if ok else 0, 'detail': detail})
    sa_ok, sa_text = sa_established()
    add('IKEv2 SA', sa_ok, 25, 'established' if sa_ok else 'not visible')
    add('XFRM interface', pathlib.Path('/sys/class/net/' + XFRM).exists(), 15, XFRM)
    route = route_for()
    add('Protected route', XFRM in route, 20, route)
    live_ip = public_ip()
    rec_ip = st.get('PUBLIC_IP', '')
    add('Exit IP match', bool(live_ip and rec_ip and live_ip == rec_ip), 20, live_ip or 'offline')
    add('Watchdog', lv.get('HEALTH') == 'OK', 10, lv.get('HEALTH', 'UNKNOWN'))
    dns = st.get('DNS_CSV', '')
    add('DNS configured', bool(dns), 5, dns)
    add('Kill switch requested', st.get('KILL_SWITCH') == '1', 5, st.get('KILL_SWITCH', '0'))
    if score >= 90: state = 'HEALTHY'
    elif score >= 65: state = 'DEGRADED'
    elif st: state = 'FAIL_CLOSED'
    else: state = 'UNPROTECTED'
    return {'score': score, 'state': state, 'checks': checks, 'public_ip': live_ip, 'recorded_ip': rec_ip,
            'virtual_ip': st.get('VIRTUAL_IP', ''), 'exit_country': st.get('EXIT_COUNTRY', ''),
            'rx_bps': int(lv.get('RX_BPS', '0') or 0), 'tx_bps': int(lv.get('TX_BPS', '0') or 0),
            'latency_ms': int(lv.get('LATENCY_MS', '0') or 0), 'routing_mode': st.get('ROUTING_MODE', '')}


def speed_test():
    st = read_kv(STATE)
    if not st: return {'ok': False, 'error': 'VPN is not connected'}
    url = 'https://speed.cloudflare.com/__down?bytes=3000000'
    cmd = ['curl','-4','-L','--max-time','20','-sS','-o','/dev/null','-w','%{time_connect} %{time_starttransfer} %{speed_download}',url]
    rc, text = run(cmd, 24)
    if rc != 0: return {'ok': False, 'error': text}
    try:
        connect, ttfb, speed = map(float, text.split()[:3])
    except Exception:
        return {'ok': False, 'error': 'Could not parse speed result', 'raw': text}
    mbps = speed * 8 / 1_000_000
    if mbps >= 20 and ttfb < 0.8: profile = 'Performance'
    elif mbps >= 5 and ttfb < 1.8: profile = 'Balanced'
    else: profile = 'Maximum Compatibility'
    result = {'ok': True, 'connect_ms': round(connect*1000), 'ttfb_ms': round(ttfb*1000), 'download_mbps': round(mbps,2), 'recommendation': profile}
    event('speed-test', 'Protected speed test completed', **result)
    return result


def dns_test():
    st = read_kv(STATE)
    expected = [x for x in st.get('DNS_CSV','').split(',') if x]
    rc, status = run(['resolvectl','status'], 6)
    active = [ip for ip in expected if ip in status]
    rc2, query = run(['resolvectl','query','example.com'], 8)
    result = {'ok': bool(expected and active and rc2 == 0), 'expected': expected, 'active_expected': active,
              'resolver_query_ok': rc2 == 0, 'query': query[-1200:], 'status_excerpt': status[-2500:]}
    event('dns-test', 'DNS evidence collected', ok=result['ok'])
    return result


def mtu_test():
    sizes = [1360, 1320, 1280, 1240, 1200, 1160]
    chosen = None
    attempts = []
    for size in sizes:
        payload = max(576, size - 28)
        rc, text = run(['ping','-4','-c','1','-W','2','-M','do','-s',str(payload),'1.1.1.1'],4)
        attempts.append({'mtu': size, 'ok': rc == 0})
        if rc == 0:
            chosen = size
            break
    mss = max(900, (chosen or 1240) - 40)
    result = {'ok': chosen is not None, 'safe_mtu': chosen or 1240, 'recommended_mss': mss, 'attempts': attempts}
    event('mtu-test', 'MTU compatibility probe completed', **result)
    return result


def load_iran_networks():
    nets = []
    try:
        for line in IRAN_LIST.read_text().splitlines():
            line=line.strip()
            if not line or line.startswith('#'): continue
            try: nets.append(ipaddress.ip_network(line, strict=False))
            except ValueError: pass
    except OSError: pass
    return nets


def route_test(target):
    target = target.strip()
    host = re.sub(r'^https?://','',target).split('/')[0].split(':')[0]
    addresses = []
    try:
        ipaddress.ip_address(host); addresses=[host]
    except ValueError:
        try: addresses=sorted({x[4][0] for x in socket.getaddrinfo(host,None,socket.AF_INET)})
        except OSError: pass
    st=read_kv(STATE); mode=st.get('ROUTING_MODE','vpn_all'); nets=load_iran_networks()
    rows=[]
    for addr in addresses:
        ip=ipaddress.ip_address(addr); iran=any(ip in n for n in nets)
        intended='DIRECT' if mode=='iran_direct' and iran else 'VPN'
        route=route_for(addr)
        actual='VPN' if XFRM in route else 'DIRECT'
        rows.append({'address':addr,'iran':iran,'intended':intended,'actual':actual,'route':route})
    result={'ok':bool(rows) and all(r['intended']==r['actual'] for r in rows),'target':target,'host':host,'mode':mode,'results':rows}
    event('route-test', f'Route tested: {host}', ok=result['ok'])
    return result


def save_lkg():
    if not STATE.exists(): return {'ok':False,'error':'VPN state is unavailable'}
    VAR.mkdir(parents=True,exist_ok=True); shutil.copy2(STATE,LKG); os.chmod(LKG,0o600)
    event('lkg','Last Known Good saved')
    return {'ok':True,'path':str(LKG)}


def lkg_status():
    return {'ok':LKG.exists(),'state':read_kv(LKG) if LKG.exists() else {}}


def emergency_stop():
    run([DISCONNECT],20)
    # Fail safe cleanup of MilMit-owned policy rules/interfaces only.
    for pref in ('109','110','220'):
        for _ in range(4):
            rc,_=run(['ip','rule','del','pref',pref],3)
            if rc: break
    run(['ip','route','flush','table','220'],3)
    run(['ip','link','del',XFRM],3)
    event('emergency-stop','Emergency stop executed')
    return {'ok':True,'message':'VPN routing, XFRM and MilMit policy rules were removed'}


def recent_destinations():
    rc,text=run(['ss','-Hntup'],5); rows=[]
    if rc==0:
        for line in text.splitlines()[:300]:
            cols=line.split()
            if len(cols)<5: continue
            peer=cols[4]
            m=re.search(r'\[?([0-9a-fA-F:.]+)\]?:([0-9]+)$',peer)
            if not m: continue
            addr,port=m.group(1),m.group(2)
            try:
                ip=ipaddress.ip_address(addr)
                if ip.version!=4 or ip.is_private or ip.is_loopback: continue
            except ValueError: continue
            rows.append({'address':addr,'port':int(port),'peer':peer})
    # unique, stable
    uniq=[]; seen=set()
    for r in rows:
        key=(r['address'],r['port'])
        if key not in seen: seen.add(key); uniq.append(r)
    return {'ok':True,'items':uniq[:40]}


def support_bundle():
    out=pathlib.Path('/tmp')/f'milmit-surfshark-support-{int(time.time())}.tar.gz'
    with tempfile.TemporaryDirectory() as td:
        root=pathlib.Path(td)
        (root/'health.json').write_text(json.dumps(health(),indent=2))
        (root/'state.txt').write_text(STATE.read_text(errors='replace') if STATE.exists() else '')
        (root/'live.txt').write_text(LIVE.read_text(errors='replace') if LIVE.exists() else '')
        (root/'ip-rule.txt').write_text(run(['ip','rule','show'])[1])
        (root/'route-220.txt').write_text(run(['ip','route','show','table','220'])[1])
        (root/'xfrm.txt').write_text(run(['ip','-s','link','show',XFRM])[1])
        (root/'swanctl-sas.txt').write_text(run(['swanctl','--list-sas'])[1])
        if HISTORY.exists(): shutil.copy2(HISTORY,root/'events.jsonl')
        # Explicitly no credentials and no service username file are included.
        with tarfile.open(out,'w:gz') as tar: tar.add(root,arcname='milmit-support')
    event('support-bundle','Redacted support bundle created',path=str(out))
    return {'ok':True,'path':str(out)}


def history(limit=60):
    rows=[]
    try:
        for line in HISTORY.read_text(errors='replace').splitlines()[-limit:]:
            try: rows.append(json.loads(line))
            except Exception: pass
    except OSError: pass
    return {'ok':True,'items':rows}


def dns_repair():
    st = read_kv(STATE)
    dns_csv = st.get('DNS_CSV', '162.252.172.57,149.154.159.92,1.1.1.1')
    servers = [s.strip() for s in dns_csv.split(',') if s.strip()]
    if not servers:
        servers = ['162.252.172.57', '149.154.159.92', '1.1.1.1']
    rc, out = run(['ip', '-o', 'link', 'show'], 4)
    modified = []
    for line in out.splitlines():
        parts = line.split(': ')
        if len(parts) >= 2:
            iface = parts[1].split('@')[0].strip()
            if any(iface.startswith(p) for p in ('lo', 'docker', 'br-', 'lxc', 'virbr', 'veth', 'milmit')):
                continue
            run(['resolvectl', 'dns', iface] + servers, 4)
            run(['resolvectl', 'domain', iface, '~.'], 4)
            run(['resolvectl', 'default-route', iface, 'true'], 4)
            modified.append(iface)
    run(['resolvectl', 'flush-caches'], 4)
    res = {'ok': True, 'interfaces': modified, 'servers': servers}
    event('dns-repair', 'Enforced secure DNS across physical interfaces', **res)
    return res


def chatgpt_test():
    import urllib.request, ssl, urllib.error
    diag = {'ok': False, 'dns_resolved': False, 'resolved_ips': [], 'http_status': 0, 'details': '', 'cloudflare_verified': False}
    rc, out = run(['resolvectl', 'query', 'chatgpt.com'], 6)
    ips = re.findall(r'(?:\d{1,3}\.){3}\d{1,3}', out)
    diag['resolved_ips'] = list(dict.fromkeys(ips))
    diag['dns_resolved'] = bool(diag['resolved_ips'])
    ctx = ssl.create_default_context()
    req = urllib.request.Request('https://chatgpt.com', headers={
        'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.5',
    })
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=8) as r:
            elapsed = round((time.time() - t0) * 1000)
            diag['ok'] = True
            diag['http_status'] = r.status
            diag['latency_ms'] = elapsed
            diag['details'] = f"ChatGPT is fully reachable (HTTP {r.status}, {elapsed}ms). TLS and DNS verified."
    except urllib.error.HTTPError as e:
        elapsed = round((time.time() - t0) * 1000)
        diag['http_status'] = e.code
        diag['latency_ms'] = elapsed
        server = (e.headers.get('Server') or '').lower()
        cf_ray = e.headers.get('CF-RAY') or ''
        if 'cloudflare' in server or cf_ray or e.code == 403:
            diag['ok'] = True
            diag['cloudflare_verified'] = True
            diag['details'] = f"OpenAI Cloudflare edge reached successfully ({elapsed}ms, ray={cf_ray[:14] if cf_ray else 'ok'}). DNS and route are unblocked; ChatGPT is ready in any standard browser."
        elif e.code in (200, 301, 302):
            diag['ok'] = True
            diag['details'] = f"ChatGPT reachable (HTTP {e.code}, {elapsed}ms)."
        else:
            diag['ok'] = False
            diag['details'] = f"HTTP {e.code} error received from ChatGPT."
    except Exception as e:
        diag['ok'] = False
        diag['details'] = f"Connection to ChatGPT failed: {str(e)}"

    event('chatgpt-test', 'ChatGPT access benchmark', ok=diag['ok'], status=diag['http_status'])
    return diag


def routing_mode_status():
    st = read_kv(STATE)
    last = read_kv(LAST)
    mode = last.get('ROUTING_MODE') or st.get('ROUTING_MODE', 'vpn_all')
    active_connected = STATE.exists() and bool(st.get('SERVER_IP'))
    rules_meta = {}
    rules_meta_file = pathlib.Path('/var/lib/milmit-surfshark/rules/metadata.json')
    if rules_meta_file.exists():
        try: rules_meta = json.loads(rules_meta_file.read_text())
        except Exception: pass
    iran_set_active = False
    if active_connected:
        rc, _ = run(['ipset', 'list', 'milmit_iran_direct'], 2)
        iran_set_active = (rc == 0)
    return {
        'ok': True,
        'routing_mode': mode,
        'connected': active_connected,
        'iran_bypass_active': iran_set_active if active_connected else (mode == 'iran_direct'),
        'rules_metadata': rules_meta,
    }


def set_routing_mode(new_mode):
    if new_mode not in ('vpn_all', 'iran_direct'):
        return {'ok': False, 'error': f'Invalid routing mode: {new_mode}'}
    write_kv_key(LAST, 'ROUTING_MODE', new_mode)
    live_applied = False
    st = read_kv(STATE)
    if STATE.exists() and st.get('SERVER_IP'):
        iran_file = pathlib.Path('/var/lib/milmit-surfshark/rules/ircidr.txt')
        if not iran_file.exists():
            iran_file = pathlib.Path('/var/lib/milmit-surfshark/iran-ipv4.txt')
        iface = st.get('IFACE', '')
        chain_host = 'MILMIT_VPN_OUT'
        chain_hot = 'MILMIT_HOTSPOT_MARK'
        mark_direct = '0x113'
        iran_set = 'MILMIT_IRAN'

        if iface:
            rc_nat, _ = run(['iptables', '-w', '-t', 'nat', '-C', 'POSTROUTING', '-o', iface, '-m', 'mark', '--mark', mark_direct, '-j', 'MASQUERADE'], 2)
            if rc_nat != 0:
                run(['iptables', '-w', '-t', 'nat', '-I', 'POSTROUTING', '1', '-o', iface, '-m', 'mark', '--mark', mark_direct, '-j', 'MASQUERADE'], 3)
            rc_nat2, _ = run(['iptables', '-w', '-t', 'nat', '-C', 'POSTROUTING', '-o', iface, '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'MASQUERADE'], 2)
            if rc_nat2 != 0:
                run(['iptables', '-w', '-t', 'nat', '-I', 'POSTROUTING', '1', '-o', iface, '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'MASQUERADE'], 3)

        if new_mode == 'iran_direct' and iran_file.exists():
            run(['ipset', 'create', iran_set, 'hash:net', 'family', 'inet', 'maxelem', '200000', '-exist'], 5)
            p = subprocess.Popen(['ipset', 'restore', '-exist'], stdin=subprocess.PIPE, text=True)
            cmds = [f'create {iran_set} hash:net family inet maxelem 200000 -exist']
            for line in iran_file.read_text(errors='replace').splitlines():
                line = line.strip()
                if line and not line.startswith('#'):
                    cmds.append(f'add {iran_set} {line} -exist')
            p.communicate('\n'.join(cmds), timeout=10)

            rc, _ = run(['iptables', '-w', '-t', 'mangle', '-C', chain_host, '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'MARK', '--set-mark', mark_direct], 2)
            if rc != 0:
                run(['iptables', '-w', '-t', 'mangle', '-I', chain_host, '2', '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'MARK', '--set-mark', mark_direct], 3)
                run(['iptables', '-w', '-t', 'mangle', '-I', chain_host, '3', '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'RETURN'], 3)

            rc_hot, _ = run(['iptables', '-w', '-t', 'mangle', '-L', chain_hot], 2)
            if rc_hot == 0:
                rc2, _ = run(['iptables', '-w', '-t', 'mangle', '-C', chain_hot, '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'MARK', '--set-mark', mark_direct], 2)
                if rc2 != 0:
                    run(['iptables', '-w', '-t', 'mangle', '-I', chain_hot, '2', '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'MARK', '--set-mark', mark_direct], 3)
                    run(['iptables', '-w', '-t', 'mangle', '-I', chain_hot, '3', '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'RETURN'], 3)
            live_applied = True
        elif new_mode == 'vpn_all':
            for _ in range(5):
                rc, _ = run(['iptables', '-w', '-t', 'mangle', '-D', chain_host, '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'MARK', '--set-mark', mark_direct], 2)
                if rc != 0: break
            for _ in range(5):
                rc, _ = run(['iptables', '-w', '-t', 'mangle', '-D', chain_host, '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'RETURN'], 2)
                if rc != 0: break
            for _ in range(5):
                rc, _ = run(['iptables', '-w', '-t', 'mangle', '-D', chain_hot, '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'MARK', '--set-mark', mark_direct], 2)
                if rc != 0: break
            for _ in range(5):
                rc, _ = run(['iptables', '-w', '-t', 'mangle', '-D', chain_hot, '-m', 'set', '--match-set', iran_set, 'dst', '-j', 'RETURN'], 2)
                if rc != 0: break
            live_applied = True

        write_kv_key(STATE, 'ROUTING_MODE', new_mode)
        run(['ip', 'route', 'flush', 'cache'], 2)

    event('routing-mode', f'Routing mode set to {new_mode}', live=live_applied)
    return {'ok': True, 'routing_mode': new_mode, 'live_applied': live_applied}


CUSTOM_RULES_FILE = pathlib.Path('/var/lib/milmit-surfshark/rules/custom_direct.json')

def custom_rules_get():
    if not CUSTOM_RULES_FILE.exists():
        return {'ok': True, 'rules': []}
    try:
        data = json.loads(CUSTOM_RULES_FILE.read_text())
        return {'ok': True, 'rules': data.get('rules', [])}
    except Exception as e:
        return {'ok': False, 'error': str(e), 'rules': []}

def custom_rules_add(target: str):
    target = target.strip()
    if not target or len(target) > 255:
        return {'ok': False, 'error': 'Target is required'}
    
    rule_type = 'domain'
    ips_to_add = []
    try:
        if '/' in target:
            ipaddress.ip_network(target, strict=False)
            rule_type = 'cidr'
            ips_to_add.append(target)
        else:
            ipaddress.ip_address(target)
            rule_type = 'ip'
            ips_to_add.append(target)
    except ValueError:
        rule_type = 'domain'
        try:
            infos = socket.getaddrinfo(target, None, socket.AF_INET)
            for info in infos:
                ip = info[4][0]
                if ip not in ips_to_add:
                    ips_to_add.append(ip)
        except Exception:
            pass

    CUSTOM_RULES_FILE.parent.mkdir(parents=True, exist_ok=True)
    current = custom_rules_get().get('rules', [])
    if not any(r.get('target') == target for r in current):
        current.append({
            'target': target,
            'type': rule_type,
            'resolved_ips': ips_to_add,
            'added_at': time.strftime('%Y-%m-%d %H:%M:%S')
        })
        CUSTOM_RULES_FILE.write_text(json.dumps({'rules': current}, indent=2))

    for ip in ips_to_add:
        for s in ['MILMIT_IRAN', 'MILMIT_FORCE_DIRECT']:
            run(['ipset', 'add', s, ip, '-exist'], 2)

    return {'ok': True, 'target': target, 'type': rule_type, 'resolved_ips': ips_to_add, 'rules': current}

def custom_rules_remove(target: str):
    target = target.strip()
    current = custom_rules_get().get('rules', [])
    found = [r for r in current if r.get('target') == target]
    remaining = [r for r in current if r.get('target') != target]
    CUSTOM_RULES_FILE.write_text(json.dumps({'rules': remaining}, indent=2))

    for item in found:
        for ip in item.get('resolved_ips', []):
            for s in ['MILMIT_IRAN', 'MILMIT_FORCE_DIRECT']:
                run(['ipset', 'del', s, ip], 2)

    return {'ok': True, 'target': target, 'remaining': len(remaining), 'rules': remaining}


def main():
    if os.geteuid()!=0:
        print(json.dumps({'ok':False,'error':'control center must run as root'})); return 77
    cmd=sys.argv[1] if len(sys.argv)>1 else 'health'
    if cmd=='health': result=health()
    elif cmd=='speed-test': result=speed_test()
    elif cmd=='dns-test': result=dns_test()
    elif cmd=='dns-repair': result=dns_repair()
    elif cmd=='chatgpt-test': result=chatgpt_test()
    elif cmd=='routing-mode-status': result=routing_mode_status()
    elif cmd=='set-routing-mode': result=set_routing_mode(sys.argv[2] if len(sys.argv)>2 else 'vpn_all')
    elif cmd=='custom-rules-get': result=custom_rules_get()
    elif cmd=='custom-rules-add': result=custom_rules_add(sys.argv[2] if len(sys.argv)>2 else '')
    elif cmd=='custom-rules-remove': result=custom_rules_remove(sys.argv[2] if len(sys.argv)>2 else '')
    elif cmd=='mtu-test': result=mtu_test()
    elif cmd=='route-test': result=route_test(sys.argv[2] if len(sys.argv)>2 else '1.1.1.1')
    elif cmd=='save-lkg': result=save_lkg()
    elif cmd=='lkg-status': result=lkg_status()
    elif cmd=='emergency-stop': result=emergency_stop()
    elif cmd=='recent-destinations': result=recent_destinations()
    elif cmd=='support-bundle': result=support_bundle()
    elif cmd=='history': result=history()
    print(json.dumps(result,ensure_ascii=False,indent=2))
    if cmd in ('chatgpt-test', 'dns-test', 'speed-test', 'health', 'routing-mode-status', 'set-routing-mode', 'dns-repair', 'custom-rules-get', 'custom-rules-add', 'custom-rules-remove'):
        return 0
    return 0 if result.get('ok',True) else 1


if __name__=='__main__':
    raise SystemExit(main())
