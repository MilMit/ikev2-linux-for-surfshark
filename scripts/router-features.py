#!/usr/bin/env python3
import ipaddress, json, os, pathlib, random, re, secrets, string, subprocess, sys, time
from datetime import datetime, timezone

STATE=pathlib.Path('/run/milmit-surfshark/restricted.state')
VAR=pathlib.Path('/var/lib/milmit-surfshark')
CFG=VAR/'router-features.json'
EVENTS=VAR/'events.jsonl'
USAGE=VAR/'device-usage.json'
GUEST=VAR/'guest-hotspot.json'
POLICY_CHAIN='MILMIT_ADV_POLICY'
BLOCK_CHAIN='MILMIT_ADV_BLOCK'
DEV_BLOCK_CHAIN='MILMIT_DEVICE_BLOCK'
FORCE_DIRECT='MILMIT_FORCE_DIRECT'
FORCE_VPN='MILMIT_FORCE_VPN'
BLOCK_SET='MILMIT_BLOCK'
MARK_VPN='0x112'; MARK_DIRECT='0x113'; XFRM='milmitxfrm0'

def run(args, timeout=12):
    try:
        p=subprocess.run(args,text=True,capture_output=True,timeout=timeout)
        return p.returncode,(p.stdout+('\n' if p.stdout and p.stderr else '')+p.stderr).strip()
    except Exception as e: return 124,str(e)

def kv(path):
    out={}
    try:
        for line in pathlib.Path(path).read_text(errors='replace').splitlines():
            if '=' in line:
                k,v=line.split('=',1); out[k]=v
    except OSError: pass
    return out

def load_json(path, default):
    try: return json.loads(path.read_text())
    except Exception: return default

def save_json(path,obj,mode=0o600):
    path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_suffix(path.suffix+'.tmp'); tmp.write_text(json.dumps(obj,ensure_ascii=False,indent=2)); os.chmod(tmp,mode); tmp.replace(path)

def event(kind,msg,**extra):
    VAR.mkdir(parents=True,exist_ok=True)
    row={'time':datetime.now(timezone.utc).isoformat(),'kind':kind,'message':msg,**extra}
    with EVENTS.open('a') as f: f.write(json.dumps(row,ensure_ascii=False)+'\n')
    os.chmod(EVENTS,0o600)

def defaults():
    return {'force_dns':True,'block_quic':False,'client_isolation':False,'ipv6_policy':'block','devices':{},'policies':[],
            'guest':{'duration_minutes':60,'speed_kbit':0},'priority':['block','force_vpn','manual_direct','iran_direct','default']}

def cfg():
    d=defaults(); cur=load_json(CFG,{})
    for k,v in cur.items(): d[k]=v
    return d

def valid_mac(mac): return bool(re.fullmatch(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}',mac.upper()))
def ipset(name): run(['ipset','create',name,'hash:net','family','inet','maxelem','200000','-exist'])
def ipt(table,*args): return run(['iptables','-w','-t',table,*args],8)
def unhook(table,base,chain):
    for _ in range(20):
        rc,_=ipt(table,'-D',base,'-j',chain)
        if rc: break

def chain(table,name):
    ipt(table,'-N',name); ipt(table,'-F',name)

def resolve_target(target):
    target=target.strip().lower(); vals=[]
    try: vals=[str(ipaddress.ip_network(target,strict=False))]
    except ValueError:
        host=re.sub(r'^https?://','',target).split('/')[0].split(':')[0]
        rc,text=run(['getent','ahostsv4',host],6)
        if rc==0:
            for line in text.splitlines():
                ip=line.split()[0]
                try:
                    ipaddress.ip_address(ip); vals.append(ip+'/32')
                except ValueError: pass
    return sorted(set(vals))

def hotspot_info():
    st=kv(STATE); iface=st.get('HOTSPOT_IFACE',''); subnet=st.get('HOTSPOT_SUBNET',''); dns=st.get('HOTSPOT_DNS','')
    clients=[]
    if iface:
        rc,text=run(['ip','neigh','show','dev',iface],5)
        if rc==0:
            for line in text.splitlines():
                m=re.search(r'^([0-9.]+).*lladdr\s+([0-9a-f:]{17})\s+(\S+)',line,re.I)
                if m: clients.append({'ip':m.group(1),'mac':m.group(2).upper(),'state':m.group(3)})
    return {'ok':bool(iface and subnet),'iface':iface,'subnet':subnet,'dns':dns,'clients':clients,'client_count':len(clients)}

def add_policy(target,policy,scope='both'):
    policy=policy.lower(); scope=scope.lower()
    if policy not in ('direct','vpn','block') or scope not in ('ubuntu','hotspot','both'): return {'ok':False,'error':'invalid policy/scope'}
    c=cfg(); rows=[x for x in c['policies'] if not (x.get('target')==target and x.get('scope')==scope)]
    rows.append({'target':target,'policy':policy,'scope':scope,'resolved':resolve_target(target),'updated':int(time.time())}); c['policies']=rows; save_json(CFG,c); apply(); event('policy',f'{target} -> {policy}',scope=scope); return {'ok':True,'policy':rows[-1]}

def remove_policy(target,scope='both'):
    c=cfg(); before=len(c['policies']); c['policies']=[x for x in c['policies'] if not (x.get('target')==target and x.get('scope')==scope)]; save_json(CFG,c); apply(); return {'ok':True,'removed':before-len(c['policies'])}

def set_device(mac,policy='default',speed_kbit=0,quota_mb=0,quota_action='notify',paused=False):
    mac=mac.upper()
    if not valid_mac(mac): return {'ok':False,'error':'invalid MAC'}
    if policy not in ('default','vpn','direct','block'): return {'ok':False,'error':'invalid device policy'}
    if quota_action not in ('notify','throttle','block'): return {'ok':False,'error':'invalid quota action'}
    c=cfg(); c['devices'][mac]={'policy':policy,'speed_kbit':max(0,int(speed_kbit)),'quota_mb':max(0,int(quota_mb)),'quota_action':quota_action,'paused':bool(paused)}; save_json(CFG,c); apply(); return {'ok':True,'mac':mac,'settings':c['devices'][mac]}

def set_options(force_dns=None,block_quic=None,client_isolation=None,ipv6_policy=None):
    c=cfg()
    if force_dns is not None: c['force_dns']=bool(force_dns)
    if block_quic is not None: c['block_quic']=bool(block_quic)
    if client_isolation is not None: c['client_isolation']=bool(client_isolation)
    if ipv6_policy is not None:
        if ipv6_policy not in ('block','allow'): return {'ok':False,'error':'ipv6 policy must be block/allow'}
        c['ipv6_policy']=ipv6_policy
    save_json(CFG,c); return apply()

def update_usage(clients):
    u=load_json(USAGE,{'day':time.strftime('%Y-%m-%d'),'devices':{}})
    today=time.strftime('%Y-%m-%d')
    if u.get('day')!=today: u={'day':today,'devices':{}}
    # Read accounting counters from per-device rules when present.
    rc,text=ipt('filter','-L',DEV_BLOCK_CHAIN,'-vnx')
    if rc==0:
        for line in text.splitlines():
            m=re.search(r'^\s*(\d+)\s+(\d+).*MAC\s+([0-9A-F:]{17})',line,re.I)
            if m:
                mac=m.group(3).upper(); u['devices'][mac]={'bytes_seen':int(m.group(2)),'updated':int(time.time())}
    save_json(USAGE,u); return u

def apply_tc(iface,clients,c):
    if not iface: return
    run(['tc','qdisc','del','dev',iface,'root'],4)
    limited=[]
    for cl in clients:
        d=c['devices'].get(cl['mac'],{}); rate=int(d.get('speed_kbit',0) or 0)
        if rate>0: limited.append((cl['ip'],rate))
    if not limited: return
    run(['tc','qdisc','add','dev',iface,'root','handle','1:','htb','default','999'],5)
    run(['tc','class','add','dev',iface,'parent','1:','classid','1:999','htb','rate','1000mbit','ceil','1000mbit'],5)
    for idx,(ip,rate) in enumerate(limited,10):
        run(['tc','class','add','dev',iface,'parent','1:','classid',f'1:{idx}','htb','rate',f'{rate}kbit','ceil',f'{rate}kbit'],5)
        run(['tc','filter','add','dev',iface,'protocol','ip','parent','1:','prio',str(idx),'u32','match','ip','dst',ip+'/32','flowid',f'1:{idx}'],5)

def apply():
    st=kv(STATE); c=cfg(); hs=hotspot_info(); iface=hs['iface']; subnet=hs['subnet']; dns=hs['dns'] or '162.252.172.57'
    # IP/CIDR/domain policy sets.
    for name in (FORCE_DIRECT,FORCE_VPN,BLOCK_SET): ipset(name); run(['ipset','flush',name])
    for p in c['policies']:
        resolved=p.get('resolved') or resolve_target(p.get('target','')); p['resolved']=resolved
        setname={'direct':FORCE_DIRECT,'vpn':FORCE_VPN,'block':BLOCK_SET}.get(p.get('policy'))
        if setname:
            for net in resolved: run(['ipset','add',setname,net,'-exist'])
    save_json(CFG,c)
    chain('mangle',POLICY_CHAIN)
    # Block is filter-only; routing priority is force VPN > manual direct > Iran/default.
    ipt('mangle','-A',POLICY_CHAIN,'-m','set','--match-set',FORCE_VPN,'dst','-j','MARK','--set-mark',MARK_VPN)
    ipt('mangle','-A',POLICY_CHAIN,'-m','set','--match-set',FORCE_VPN,'dst','-j','RETURN')
    ipt('mangle','-A',POLICY_CHAIN,'-m','set','--match-set',FORCE_DIRECT,'dst','-j','MARK','--set-mark',MARK_DIRECT)
    ipt('mangle','-A',POLICY_CHAIN,'-m','set','--match-set',FORCE_DIRECT,'dst','-j','RETURN')
    unhook('mangle','OUTPUT',POLICY_CHAIN); ipt('mangle','-I','OUTPUT','1','-j',POLICY_CHAIN)
    if iface and subnet:
        unhook('mangle','PREROUTING',POLICY_CHAIN); ipt('mangle','-I','PREROUTING','1','-i',iface,'-s',subnet,'-j',POLICY_CHAIN)
    chain('filter',BLOCK_CHAIN)
    ipt('filter','-A',BLOCK_CHAIN,'-m','set','--match-set',BLOCK_SET,'dst','-j','REJECT','--reject-with','icmp-net-unreachable')
    if c.get('block_quic'):
        ipt('filter','-A',BLOCK_CHAIN,'-p','udp','--dport','443','-j','REJECT','--reject-with','icmp-port-unreachable')
    unhook('filter','OUTPUT',BLOCK_CHAIN); ipt('filter','-I','OUTPUT','1','-j',BLOCK_CHAIN)
    unhook('filter','FORWARD',BLOCK_CHAIN); ipt('filter','-I','FORWARD','1','-j',BLOCK_CHAIN)

    chain('filter',DEV_BLOCK_CHAIN)
    for cl in hs['clients']:
        d=c['devices'].get(cl['mac'],{}); blocked=d.get('policy')=='block' or d.get('paused')
        if blocked: ipt('filter','-A',DEV_BLOCK_CHAIN,'-m','mac','--mac-source',cl['mac'],'-j','REJECT','--reject-with','icmp-net-unreachable')
        else: ipt('filter','-A',DEV_BLOCK_CHAIN,'-m','mac','--mac-source',cl['mac'],'-j','RETURN')
    unhook('filter','FORWARD',DEV_BLOCK_CHAIN); ipt('filter','-I','FORWARD','1','-j',DEV_BLOCK_CHAIN)

    # Per-device VPN/Direct integrates with existing hotspot policy helper.
    vpn=[]; direct=[]
    for mac,d in c['devices'].items():
        if d.get('policy')=='vpn': vpn.append(mac)
        elif d.get('policy')=='direct': direct.append(mac)
    if STATE.exists() and iface and subnet:
        run(['/usr/lib/milmit-surfshark/hotspot-device-policy.sh','1',','.join(vpn),','.join(direct)],20)
        if c.get('force_dns'):
            # Existing hotspot chain already DNATs DNS for VPN/default devices.
            pass
        if c.get('client_isolation'):
            ipt('filter','-I',DEV_BLOCK_CHAIN,'1','-i',iface,'-o',iface,'-j','DROP')
        if c.get('ipv6_policy')=='block':
            run(['sysctl','-q','-w',f'net.ipv6.conf.{iface}.disable_ipv6=1'],4)
        else: run(['sysctl','-q','-w',f'net.ipv6.conf.{iface}.disable_ipv6=0'],4)
        apply_tc(iface,hs['clients'],c)
    usage=update_usage(hs['clients'])
    event('apply','Advanced router policies applied',hotspot=iface,clients=len(hs['clients']))
    return {'ok':True,'hotspot':hs,'options':{k:c[k] for k in ('force_dns','block_quic','client_isolation','ipv6_policy')},'devices':c['devices'],'policies':c['policies'],'usage':usage}

def quota_enforce():
    c=cfg(); hs=hotspot_info(); u=update_usage(hs['clients']); changed=False; notices=[]
    for mac,d in c['devices'].items():
        quota=int(d.get('quota_mb',0) or 0)
        if quota<=0: continue
        seen=int(u.get('devices',{}).get(mac,{}).get('bytes_seen',0)); exceeded=seen>=quota*1024*1024
        if exceeded:
            action=d.get('quota_action','notify'); notices.append({'mac':mac,'quota_mb':quota,'bytes_seen':seen,'action':action})
            if action=='block' and not d.get('paused'): d['paused']=True; changed=True
            elif action=='throttle' and int(d.get('speed_kbit',0) or 0)!=128: d['speed_kbit']=128; changed=True
    if changed: save_json(CFG,c); apply()
    return {'ok':True,'exceeded':notices}

def guest_start(minutes=60,ssid='MilMit Guest'):
    if minutes<5 or minutes>1440: return {'ok':False,'error':'duration must be 5..1440 minutes'}
    # Pick a disconnected Wi-Fi interface, avoiding the physical uplink and active hotspot.
    st=kv(STATE); avoid={st.get('IFACE',''),st.get('HOTSPOT_IFACE','')}
    rc,text=run(['nmcli','-t','-f','DEVICE,TYPE,STATE','device','status'],6); dev=''
    if rc==0:
        for line in text.splitlines():
            p=line.split(':')
            if len(p)>=3 and p[1]=='wifi' and p[0] not in avoid: dev=p[0]; break
    if not dev: return {'ok':False,'error':'no spare Wi-Fi interface available for guest hotspot'}
    password=''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(14))
    con='MilMit Guest Hotspot'; run(['nmcli','connection','delete',con],5)
    rc,out=run(['nmcli','device','wifi','hotspot','ifname',dev,'con-name',con,'ssid',ssid,'password',password],20)
    if rc!=0: return {'ok':False,'error':out}
    run(['nmcli','connection','modify',con,'connection.autoconnect','no','ipv4.method','shared','ipv6.method','disabled'],8)
    expires=int(time.time()+minutes*60); data={'iface':dev,'connection':con,'ssid':ssid,'password':password,'expires':expires,'minutes':minutes,'wifi_uri':f'WIFI:T:WPA;S:{ssid};P:{password};;'}; save_json(GUEST,data)
    run(['systemctl','stop','milmit-guest-expire.timer'],3)
    # Transient timer calls helper as root; failure is non-fatal.
    run(['systemd-run','--unit=milmit-guest-expire','--on-active',f'{minutes}m','/usr/libexec/milmit-surfshark-helper','guest-stop'],8)
    event('guest-start','Guest hotspot started',iface=dev,expires=expires)
    return {'ok':True,**data}

def guest_stop():
    g=load_json(GUEST,{})
    if g.get('connection'): run(['nmcli','connection','down',g['connection']],10); run(['nmcli','connection','delete',g['connection']],8)
    try: GUEST.unlink()
    except OSError: pass
    event('guest-stop','Guest hotspot stopped'); return {'ok':True}

def guest_status():
    g=load_json(GUEST,{})
    if not g: return {'ok':True,'active':False}
    return {'ok':True,'active':g.get('expires',0)>time.time(),'remaining_seconds':max(0,int(g.get('expires',0)-time.time())),**g}

def status(): return {'ok':True,'hotspot':hotspot_info(),'config':cfg(),'guest':guest_status(),'usage':load_json(USAGE,{})}

def main():
    if os.geteuid()!=0: print(json.dumps({'ok':False,'error':'router feature engine must run as root'})); return 77
    VAR.mkdir(parents=True,exist_ok=True)
    cmd=sys.argv[1] if len(sys.argv)>1 else 'status'
    try:
        if cmd=='status': r=status()
        elif cmd=='apply': r=apply()
        elif cmd=='quota-enforce': r=quota_enforce()
        elif cmd=='policy-add': r=add_policy(sys.argv[2],sys.argv[3],sys.argv[4] if len(sys.argv)>4 else 'both')
        elif cmd=='policy-remove': r=remove_policy(sys.argv[2],sys.argv[3] if len(sys.argv)>3 else 'both')
        elif cmd=='device-set': r=set_device(sys.argv[2],sys.argv[3] if len(sys.argv)>3 else 'default',int(sys.argv[4]) if len(sys.argv)>4 else 0,int(sys.argv[5]) if len(sys.argv)>5 else 0,sys.argv[6] if len(sys.argv)>6 else 'notify',(sys.argv[7]=='1') if len(sys.argv)>7 else False)
        elif cmd=='options': r=set_options(sys.argv[2]=='1' if len(sys.argv)>2 else None,sys.argv[3]=='1' if len(sys.argv)>3 else None,sys.argv[4]=='1' if len(sys.argv)>4 else None,sys.argv[5] if len(sys.argv)>5 else None)
        elif cmd=='guest-start': r=guest_start(int(sys.argv[2]) if len(sys.argv)>2 else 60,sys.argv[3] if len(sys.argv)>3 else 'MilMit Guest')
        elif cmd=='guest-stop': r=guest_stop()
        elif cmd=='guest-status': r=guest_status()
        else: r={'ok':False,'error':'unknown command'}
    except (IndexError,ValueError) as e: r={'ok':False,'error':str(e)}
    print(json.dumps(r,ensure_ascii=False,indent=2)); return 0 if r.get('ok') else 1
if __name__=='__main__': raise SystemExit(main())
