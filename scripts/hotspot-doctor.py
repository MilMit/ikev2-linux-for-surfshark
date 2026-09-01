#!/usr/bin/env python3
import json, os, pathlib, re, subprocess, sys

STATE=pathlib.Path('/run/milmit-surfshark/restricted.state')
ROUTER_CFG=pathlib.Path('/var/lib/milmit-surfshark/router-features.json')
XFRM='milmitxfrm0'
MARK_VPN='0x112'
MARK_DIRECT='0x113'


def run(args, timeout=8):
    try:
        p=subprocess.run(args,text=True,capture_output=True,timeout=timeout)
        return p.returncode,(p.stdout+('\n' if p.stdout and p.stderr else '')+p.stderr).strip()
    except Exception as e:
        return 124,str(e)


def kv(path):
    out={}
    try:
        for line in path.read_text(errors='replace').splitlines():
            if '=' in line:
                k,v=line.split('=',1);out[k]=v.strip()
    except OSError: pass
    return out


def cfg():
    try:return json.loads(ROUTER_CFG.read_text())
    except Exception:return {}


def ipt(table,*args): return run(['iptables','-w','-t',table,*args],6)

def sysctl(name):
    p=pathlib.Path('/proc/sys')/name.replace('.','/')
    try:return p.read_text().strip()
    except OSError:return '?'


def main():
    if os.geteuid()!=0:
        print('Hotspot Doctor must run as root.');return 77
    st=kv(STATE); c=cfg(); rows=[]; fails=0; warns=0
    def add(level,name,detail):
        nonlocal fails,warns
        if level=='FAIL': fails+=1
        elif level=='WARN': warns+=1
        rows.append((level,name,detail))

    iface=st.get('HOTSPOT_IFACE',''); subnet=st.get('HOTSPOT_SUBNET',''); dns=st.get('HOTSPOT_DNS') or '162.252.172.57'; phys=st.get('IFACE',''); vip=st.get('VIRTUAL_IP',''); mode=st.get('ROUTING_MODE','unknown'); mss=st.get('MSS_VALUE','1200')
    if not STATE.exists():
        add('FAIL','VPN state','VPN runtime state is missing. Connect VPN before diagnosing the hotspot.')
    else:add('PASS','VPN state',f'connected state present · routing={mode}')
    if iface and pathlib.Path('/sys/class/net',iface).exists():add('PASS','Hotspot interface',f'{iface} · {subnet or "subnet missing"}')
    else:add('FAIL','Hotspot interface','No active shared Wi-Fi interface was recorded in VPN state.')
    if pathlib.Path('/sys/class/net',XFRM).exists():add('PASS','VPN interface',f'{XFRM} exists · virtual IP {vip or "unknown"}')
    else:add('FAIL','VPN interface',f'{XFRM} is missing.')

    rc,vpn_route=run(['ip','-4','route','get','1.1.1.1','mark',MARK_VPN])
    if rc==0 and f'dev {XFRM}' in vpn_route:add('PASS','VPN route mark',vpn_route)
    else:add('FAIL','VPN route mark',vpn_route or 'mark 0x112 does not resolve to XFRM')
    rc,direct_route=run(['ip','-4','route','get','1.1.1.1','mark',MARK_DIRECT])
    if rc==0 and phys and f'dev {phys}' in direct_route:add('PASS','Direct/Iran bypass mark',direct_route)
    elif rc==0:add('WARN','Direct/Iran bypass mark',direct_route)
    else:add('FAIL','Direct/Iran bypass mark',direct_route or 'mark 0x113 route lookup failed')

    if iface and subnet:
        rc,_=ipt('mangle','-C','PREROUTING','-i',iface,'-s',subnet,'-j','MILMIT_HOTSPOT_MARK')
        add('PASS' if rc==0 else 'FAIL','Hotspot route hook','MILMIT_HOTSPOT_MARK is attached to PREROUTING' if rc==0 else 'PREROUTING mark hook is missing')
        rc,_=ipt('nat','-C','PREROUTING','-i',iface,'-s',subnet,'-j','MILMIT_HOTSPOT_DNS')
        add('PASS' if rc==0 else 'FAIL','DNS interception','DNS DNAT hook is installed' if rc==0 else 'DNS DNAT hook is missing')
        rc,_=ipt('mangle','-C','FORWARD','-j','MILMIT_HOTSPOT_MSS')
        add('PASS' if rc==0 else 'FAIL','MSS protection',f'Forwarded VPN TCP uses MSS {mss}' if rc==0 else 'MILMIT_HOTSPOT_MSS is missing; some HTTPS/CDN traffic may hang')
        rc,_=ipt('filter','-C','FORWARD','-j','MILMIT_HOTSPOT_FWD')
        add('PASS' if rc==0 else 'FAIL','Forwarding','MilMit hotspot forwarding chain is active' if rc==0 else 'Hotspot forwarding chain is missing')
        if vip:
            rc,_=ipt('nat','-C','POSTROUTING','-s',subnet,'-o',XFRM,'-j','SNAT','--to-source',vip)
            add('PASS' if rc==0 else 'FAIL','VPN NAT','VPN client traffic is SNATed to the assigned virtual IP' if rc==0 else 'VPN SNAT rule is missing')
        if phys:
            rc,_=ipt('nat','-C','POSTROUTING','-s',subnet,'-o',phys,'-m','mark','--mark',MARK_DIRECT,'-j','MASQUERADE')
            add('PASS' if rc==0 else 'FAIL','Direct NAT','Iran/Direct traffic has explicit MASQUERADE' if rc==0 else 'Direct MASQUERADE is missing; bypass sites can fail after firewall/NM refresh')

    rc,_=run(['ping','-n','-c','1','-W','2',dns],4)
    add('PASS' if rc==0 else 'WARN','VPN DNS reachability',f'{dns} responds' if rc==0 else f'{dns} did not answer ICMP; DNS may still work, but verify resolver reachability')
    rc,resolved=run(['getent','ahostsv4','example.com'],5)
    add('PASS' if rc==0 and resolved else 'FAIL','DNS resolution','System resolver can resolve IPv4 names' if rc==0 and resolved else 'IPv4 DNS lookup failed on the host')

    block_quic=bool(c.get('block_quic'))
    if block_quic:
        rc,_=ipt('filter','-C','MILMIT_ADV_BLOCK','-p','udp','--dport','443','-j','REJECT','--reject-with','icmp-port-unreachable')
        add('PASS' if rc==0 else 'WARN','QUIC policy','UDP/443 is blocked so apps fall back to TCP' if rc==0 else 'Block QUIC is enabled in config but rule was not found')
    else:add('INFO','QUIC policy','UDP/443 is allowed. If Instagram/HTTPS stalls, temporarily enable Block QUIC to test TCP fallback.')

    if iface:
        add('PASS' if sysctl(f'net.ipv4.conf.{iface}.rp_filter')=='0' else 'WARN','Hotspot rp_filter',f'{iface}={sysctl(f"net.ipv4.conf.{iface}.rp_filter")} · expected 0 for asymmetric policy routing')
    add('PASS' if sysctl('net.ipv4.conf.all.rp_filter') in ('0','2') else 'WARN','Global rp_filter',f'all={sysctl("net.ipv4.conf.all.rp_filter")} · expected loose/off')

    if subnet and shutil_which('conntrack'):
        rc,text=run(['conntrack','-L','-s',subnet],8)
        if rc not in (0,1):add('WARN','Conntrack','Could not inspect conntrack table')
        else:add('INFO','Conntrack',f'{len([x for x in text.splitlines() if x.strip()])} tracked flows sourced from {subnet}')
    if mode=='iran_direct':
        rc,text=run(['ipset','list','MILMIT_IRAN'],6)
        m=re.search(r'Number of entries:\s*(\d+)',text)
        count=int(m.group(1)) if m else 0
        add('PASS' if rc==0 and count>100 else 'FAIL','Iran bypass set',f'{count} CIDR entries active' if count else 'MILMIT_IRAN is missing/empty; Iran bypass cannot classify destinations')

    rc,trace=run(['curl','-4','-ksS','--connect-timeout','5','--max-time','10','https://1.1.1.1/cdn-cgi/trace'],12)
    add('PASS' if rc==0 and 'ip=' in trace else 'WARN','Host HTTPS data path','VPN host path can complete HTTPS' if rc==0 and 'ip=' in trace else 'Host HTTPS probe failed; hotspot failures may be upstream of Wi-Fi sharing')

    print('MilMit Hotspot Doctor')
    print(f'Interface: {iface or "not detected"} · Subnet: {subnet or "unknown"} · Mode: {mode} · MSS: {mss}')
    print('')
    for level,name,detail in rows: print(f'[{level}] {name}: {detail}')
    print('')
    overall='HEALTHY' if fails==0 and warns==0 else 'CHECK' if fails==0 else 'DEGRADED'
    print(f'Overall: {overall} · failures={fails} · warnings={warns}')
    if fails or warns:
        print('Suggested next step: run “Repair hotspot routing”, then Hotspot Doctor again. If only QUIC warns and apps still stall, enable Block QUIC and retest.')
    return 0


def shutil_which(name):
    import shutil
    return shutil.which(name)

if __name__=='__main__': raise SystemExit(main())
