#!/usr/bin/env python3
import importlib.util, ipaddress, json, os, pathlib, re, shutil, socket, subprocess, sys, tempfile, time

VAR=pathlib.Path('/var/lib/milmit-surfshark')
STATE=pathlib.Path('/run/milmit-surfshark/restricted.state')
SNAP=VAR/'apply-snapshot.json'
CAND=VAR/'recent-candidates.json'
ROUTER='/usr/lib/milmit-surfshark/router-features.py'
RULES='/usr/lib/milmit-surfshark/rules-update.py'

def run(args,timeout=20):
    try:
        p=subprocess.run(args,text=True,capture_output=True,timeout=timeout)
        return p.returncode,(p.stdout+('\n' if p.stdout and p.stderr else '')+p.stderr).strip()
    except Exception as e:return 124,str(e)

def load_router():
    spec=importlib.util.spec_from_file_location('milmit_router',ROUTER)
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def snapshot():
    data={}
    for name,args in {
        'ip_rule':['ip','rule','show'], 'table220':['ip','route','show','table','220'],
        'mangle':['iptables-save','-t','mangle'], 'filter':['iptables-save','-t','filter'],
        'nat':['iptables-save','-t','nat']}.items(): data[name]=run(args,8)[1]
    data['router_config']=pathlib.Path('/var/lib/milmit-surfshark/router-features.json').read_text(errors='replace') if pathlib.Path('/var/lib/milmit-surfshark/router-features.json').exists() else ''
    data['time']=int(time.time());VAR.mkdir(parents=True,exist_ok=True);SNAP.write_text(json.dumps(data));os.chmod(SNAP,0o600);return data

def verify():
    checks={}
    checks['state']=STATE.exists()
    checks['xfrm']=pathlib.Path('/sys/class/net/milmitxfrm0').exists()
    route=run(['ip','-4','route','get','1.1.1.1'],5)[1];checks['route']='milmitxfrm0' in route
    rc,trace=run(['curl','-4','--connect-timeout','5','--max-time','12','-ks','https://1.1.1.1/cdn-cgi/trace'],15)
    checks['https']=rc==0 and 'ip=' in trace
    hs=load_router().hotspot_info();checks['hotspot']=True
    if hs.get('iface') and hs.get('subnet'):
        fwd=run(['iptables','-w','-t','filter','-C','FORWARD','-i',hs['iface'],'-s',hs['subnet'],'-j','ACCEPT'],5)[0]==0
        checks['hotspot_forward']=fwd
    return {'ok':all(checks.values()),'checks':checks,'route':route,'trace':trace[-500:]}

def apply_safe():
    snapshot();m=load_router();result=m.apply();v=verify()
    if result.get('ok') and v.get('ok'):
        run(['/usr/libexec/milmit-surfshark-helper','save-lkg'],8)
        return {'ok':True,'applied':result,'verification':v,'rollback':False}
    # Conservative rollback: remove only advanced policy engine and re-apply previous config when saved.
    for table,base,chain in [('mangle','OUTPUT','MILMIT_ADV_POLICY'),('mangle','PREROUTING','MILMIT_ADV_POLICY'),('filter','OUTPUT','MILMIT_ADV_BLOCK'),('filter','FORWARD','MILMIT_ADV_BLOCK'),('filter','FORWARD','MILMIT_DEVICE_BLOCK')]:
        for _ in range(10):
            rc,_=run(['iptables','-w','-t',table,'-D',base,'-j',chain],4)
            if rc:break
    return {'ok':False,'applied':result,'verification':v,'rollback':True,'error':'live verification failed; advanced hooks rolled back'}

def recent_candidates():
    items=[];seen=set()
    rc,text=run(['ss','-Hntup'],5)
    if rc==0:
        for line in text.splitlines()[:500]:
            cols=line.split()
            for token in cols:
                m=re.search(r'(?:\[)?((?:\d{1,3}\.){3}\d{1,3})(?:\])?:(\d+)$',token)
                if not m:continue
                ip=m.group(1)
                try:
                    obj=ipaddress.ip_address(ip)
                    if obj.is_private or obj.is_loopback:continue
                except ValueError:continue
                key=(ip,int(m.group(2)))
                if key not in seen:seen.add(key);items.append({'address':ip,'port':key[1],'source':'ss'})
    if shutil.which('conntrack'):
        rc,text=run(['conntrack','-L','-f','ipv4'],8)
        if rc==0:
            for ip in re.findall(r'dst=((?:\d{1,3}\.){3}\d{1,3})',text):
                try:
                    obj=ipaddress.ip_address(ip)
                    if obj.is_private or obj.is_loopback:continue
                except ValueError:continue
                key=(ip,0)
                if key not in seen:seen.add(key);items.append({'address':ip,'port':0,'source':'conntrack'})
    old=[]
    try:old=json.loads(CAND.read_text()).get('items',[])
    except Exception:pass
    merged=[];keys=set()
    for x in items+old:
        k=(x.get('address'),x.get('port',0))
        if k not in keys:keys.add(k);merged.append(x)
    data={'ok':True,'updated':int(time.time()),'items':merged[:100]};VAR.mkdir(parents=True,exist_ok=True);CAND.write_text(json.dumps(data,indent=2));os.chmod(CAND,0o600);return data

def candidate_action(addr,action):
    if action=='dismiss':
        d=recent_candidates();d['items']=[x for x in d['items'] if x.get('address')!=addr];CAND.write_text(json.dumps(d,indent=2));return {'ok':True}
    policy={'direct':'direct','vpn':'vpn','block':'block'}.get(action)
    if not policy:return {'ok':False,'error':'action must be direct/vpn/block/dismiss'}
    return load_router().add_policy(addr,policy,'both')

def low_power(mode):
    if mode=='lock':return {'ok':run(['loginctl','lock-session'],5)[0]==0,'mode':mode}
    if mode=='screen-off':
        rc,out=run(['bash','-lc','command -v gdbus >/dev/null && gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.SetPowerSaveMode 3'],6)
        return {'ok':rc==0,'mode':mode,'detail':out}
    if mode=='keep-awake':
        return {'ok':True,'mode':mode,'detail':'Use the installed systemd sleep inhibitor service while hotspot is active.'}
    return {'ok':False,'error':'mode must be lock/screen-off/keep-awake'}

def route_explain(target):
    host=re.sub(r'^https?://','',target).split('/')[0].split(':')[0]
    ips=[]
    try:ips=[str(ipaddress.ip_address(host))]
    except ValueError:
        try:ips=sorted({x[4][0] for x in socket.getaddrinfo(host,None,socket.AF_INET)})
        except OSError:pass
    m=load_router();c=m.cfg();pol=[]
    for ip in ips:
        selected='default';why='profile default'
        for p in c.get('policies',[]):
            nets=p.get('resolved') or m.resolve_target(p.get('target',''))
            try:
                if any(ipaddress.ip_address(ip) in ipaddress.ip_network(n,strict=False) for n in nets):selected=p.get('policy');why='manual policy';break
            except ValueError:pass
        route=run(['ip','-4','route','get',ip],4)[1]
        pol.append({'address':ip,'policy':selected,'reason':why,'actual':'vpn' if 'milmitxfrm0' in route else 'direct','route':route})
    return {'ok':bool(pol),'target':target,'results':pol,'priority':['block','force_vpn','manual_direct','iran_direct','default']}

def main():
    if os.geteuid()!=0:print(json.dumps({'ok':False,'error':'advanced router must run as root'}));return 77
    cmd=sys.argv[1] if len(sys.argv)>1 else 'verify'
    if cmd=='apply-safe':r=apply_safe()
    elif cmd=='verify':r=verify()
    elif cmd=='candidates':r=recent_candidates()
    elif cmd=='candidate-action':r=candidate_action(sys.argv[2],sys.argv[3])
    elif cmd=='route-explain':r=route_explain(sys.argv[2])
    elif cmd=='rules-update':r=json.loads(run([RULES,'update-force'],90)[1] or '{}')
    elif cmd=='rules-status':r=json.loads(run([RULES,'status'],10)[1] or '{}')
    elif cmd=='low-power':r=low_power(sys.argv[2])
    else:r={'ok':False,'error':'unknown command'}
    print(json.dumps(r,ensure_ascii=False,indent=2));return 0 if r.get('ok') else 1
if __name__=='__main__':raise SystemExit(main())
