#!/usr/bin/env python3
import configparser, json, os, pathlib, re, shlex, shutil, subprocess, sys, time

VAR=pathlib.Path('/var/lib/milmit-surfshark')
CFG=VAR/'desktop-features.json'
STATE=pathlib.Path('/run/milmit-surfshark/restricted.state')
LAST=VAR/'last-profile.state'
HELPER='/usr/libexec/milmit-surfshark-helper'
NS='milmit-direct'
VETH_HOST='milmitd0'; VETH_NS='milmitd1'; SUBNET='10.254.42.0/30'; HOST_IP='10.254.42.1/30'; NS_IP='10.254.42.2/30'; NS_ADDR='10.254.42.2'
CHAIN='MILMIT_APP_DIRECT'; LOCK='MILMIT_LOCKDOWN'

def run(args,timeout=15,check=False):
    p=subprocess.run(args,text=True,capture_output=True,timeout=timeout)
    if check and p.returncode: raise RuntimeError((p.stdout+'\n'+p.stderr).strip())
    return p.returncode,(p.stdout+('\n' if p.stdout and p.stderr else '')+p.stderr).strip()

def kv(path):
    out={}
    try:
        for line in pathlib.Path(path).read_text(errors='replace').splitlines():
            if '=' in line:
                k,v=line.split('=',1); out[k]=v.strip()
    except OSError: pass
    return out

def load():
    d={'auto_connect':False,'lockdown':False}
    try:d.update(json.loads(CFG.read_text()))
    except Exception:pass
    return d

def save(d):
    VAR.mkdir(parents=True,exist_ok=True);tmp=CFG.with_suffix('.tmp');tmp.write_text(json.dumps(d,indent=2));os.chmod(tmp,0o600);tmp.replace(CFG)

def sysctl_forward(): run(['sysctl','-qw','net.ipv4.ip_forward=1'])
def unhook(table,base,chain):
    for _ in range(20):
        rc,_=run(['iptables','-w','-t',table,'-D',base,'-j',chain])
        if rc: break

def chain(table,name): run(['iptables','-w','-t',table,'-N',name]);run(['iptables','-w','-t',table,'-F',name])

def physical_iface():
    st=kv(STATE); ifc=st.get('IFACE','')
    if ifc and pathlib.Path('/sys/class/net',ifc).exists(): return ifc
    rc,out=run(['ip','-4','route','get','1.1.1.1','table','main'])
    m=re.search(r'\bdev\s+(\S+)',out); return m.group(1) if m else ''

def setup_direct_ns():
    ifc=physical_iface()
    if not ifc: raise RuntimeError('Could not determine the physical uplink for Direct app routing.')
    sysctl_forward()
    run(['ip','netns','add',NS])
    if not pathlib.Path('/sys/class/net',VETH_HOST).exists():
        run(['ip','link','add',VETH_HOST,'type','veth','peer','name',VETH_NS],check=True)
        run(['ip','link','set',VETH_NS,'netns',NS],check=True)
    run(['ip','addr','replace',HOST_IP,'dev',VETH_HOST]); run(['ip','link','set',VETH_HOST,'up'])
    run(['ip','netns','exec',NS,'ip','addr','replace',NS_IP,'dev',VETH_NS]);run(['ip','netns','exec',NS,'ip','link','set','lo','up']);run(['ip','netns','exec',NS,'ip','link','set',VETH_NS,'up'])
    run(['ip','netns','exec',NS,'ip','route','replace','default','via','10.254.42.1'])
    netns_dir=pathlib.Path('/etc/netns')/NS;netns_dir.mkdir(parents=True,exist_ok=True)
    resolv=pathlib.Path('/etc/resolv.conf')
    try:(netns_dir/'resolv.conf').write_text(resolv.read_text())
    except Exception:(netns_dir/'resolv.conf').write_text('nameserver 1.1.1.1\n')
    # Mark namespace traffic Direct before host policy routing and NAT it to the physical uplink.
    run(['iptables','-w','-t','mangle','-C','PREROUTING','-s',NS_ADDR+'/32','-j','MARK','--set-mark','0x113']) or run(['iptables','-w','-t','mangle','-I','PREROUTING','1','-s',NS_ADDR+'/32','-j','MARK','--set-mark','0x113'])
    run(['iptables','-w','-t','nat','-C','POSTROUTING','-s',SUBNET,'-o',ifc,'-j','MASQUERADE']) or run(['iptables','-w','-t','nat','-A','POSTROUTING','-s',SUBNET,'-o',ifc,'-j','MASQUERADE'])
    chain('filter',CHAIN);run(['iptables','-w','-t','filter','-A',CHAIN,'-s',SUBNET,'-j','ACCEPT']);run(['iptables','-w','-t','filter','-A',CHAIN,'-d',SUBNET,'-m','conntrack','--ctstate','ESTABLISHED,RELATED','-j','ACCEPT'])
    unhook('filter','FORWARD',CHAIN);run(['iptables','-w','-t','filter','-I','FORWARD','1','-j',CHAIN])
    return ifc

def desktop_paths(uid):
    import pwd
    home=pathlib.Path(pwd.getpwuid(uid).pw_dir)
    return [home/'.local/share/applications',pathlib.Path('/usr/local/share/applications'),pathlib.Path('/usr/share/applications')]

def find_desktop(desktop_id,uid):
    if not re.fullmatch(r'[A-Za-z0-9_.+-]+\.desktop',desktop_id): raise RuntimeError('Invalid desktop application id.')
    for base in desktop_paths(uid):
        p=base/desktop_id
        if p.is_file(): return p
    raise RuntimeError('Desktop application was not found.')

def desktop_exec(path):
    cp=configparser.ConfigParser(interpolation=None,strict=False);cp.read(path,encoding='utf-8')
    sec=cp['Desktop Entry']; raw=sec.get('Exec','').strip()
    if not raw: raise RuntimeError('Application has no Exec command.')
    parts=[x for x in shlex.split(raw) if not re.fullmatch(r'%[fFuUdDnNickvm]',x)]
    if not parts: raise RuntimeError('Application Exec command is empty.')
    exe=parts[0]
    if '/' not in exe:
        resolved=shutil.which(exe)
        if not resolved: raise RuntimeError(f'Executable not found: {exe}')
        parts[0]=resolved
    elif not pathlib.Path(exe).is_file(): raise RuntimeError('Application executable was not found.')
    return parts,sec.get('Name',path.stem)

def caller_uid():
    v=os.environ.get('PKEXEC_UID') or os.environ.get('SUDO_UID')
    if v and v.isdigit(): return int(v)
    return 1000

def launch_direct(desktop_id):
    uid=caller_uid(); path=find_desktop(desktop_id,uid);args,name=desktop_exec(path);setup_direct_ns()
    import pwd
    pw=pwd.getpwuid(uid);runtime=f'/run/user/{uid}'
    env=['HOME='+pw.pw_dir,'USER='+pw.pw_name,'LOGNAME='+pw.pw_name,'XDG_RUNTIME_DIR='+runtime,'DBUS_SESSION_BUS_ADDRESS=unix:path='+runtime+'/bus']
    if pathlib.Path(runtime+'/wayland-0').exists():env.append('WAYLAND_DISPLAY=wayland-0')
    env.append('DISPLAY=:0')
    cmd=['ip','netns','exec',NS,'runuser','-u',pw.pw_name,'--','env',*env,*args]
    subprocess.Popen(cmd,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    return {'ok':True,'name':name,'desktop_id':desktop_id,'mode':'direct'}

def apply_lockdown(enabled=None):
    d=load()
    if enabled is not None:d['lockdown']=bool(enabled);save(d)
    enabled=bool(d.get('lockdown'))
    unhook('filter','OUTPUT',LOCK)
    run(['iptables','-w','-t','filter','-F',LOCK]);run(['iptables','-w','-t','filter','-X',LOCK])
    if not enabled:return {'ok':True,'lockdown':False}
    # When the VPN is healthy, normal VPN kill-switch policy is authoritative.
    if pathlib.Path('/sys/class/net/milmitxfrm0').exists() and STATE.exists(): return {'ok':True,'lockdown':True,'active_block':False}
    chain('filter',LOCK)
    run(['iptables','-w','-t','filter','-A',LOCK,'-o','lo','-j','RETURN'])
    run(['iptables','-w','-t','filter','-A',LOCK,'-m','conntrack','--ctstate','ESTABLISHED,RELATED','-j','RETURN'])
    for net in ('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','169.254.0.0/16'):
        run(['iptables','-w','-t','filter','-A',LOCK,'-d',net,'-j','RETURN'])
    run(['iptables','-w','-t','filter','-A',LOCK,'-p','udp','--sport','68','--dport','67','-j','RETURN'])
    last=kv(LAST);endpoint=last.get('SERVER_IP','')
    if re.fullmatch(r'(?:\d{1,3}\.){3}\d{1,3}',endpoint):
        for port in ('500','4500'):run(['iptables','-w','-t','filter','-A',LOCK,'-d',endpoint,'-p','udp','--dport',port,'-j','RETURN'])
    run(['iptables','-w','-t','filter','-A',LOCK,'-j','REJECT','--reject-with','icmp-net-unreachable'])
    run(['iptables','-w','-t','filter','-I','OUTPUT','1','-j',LOCK])
    return {'ok':True,'lockdown':True,'active_block':True}

def set_autoconnect(enabled):
    d=load();d['auto_connect']=bool(enabled);save(d)
    unit='milmit-surfshark-autoconnect.service'
    if enabled:run(['systemctl','enable',unit]);
    else:run(['systemctl','disable',unit])
    return {'ok':True,'auto_connect':bool(enabled)}

def status():
    d=load();return {'ok':True,**d,'lockdown_blocking':bool(d.get('lockdown')) and not STATE.exists(),'direct_namespace':pathlib.Path('/var/run/netns/'+NS).exists()}

def main():
    if os.geteuid()!=0: print(json.dumps({'ok':False,'error':'desktop feature backend must run as root'}));return 77
    cmd=sys.argv[1] if len(sys.argv)>1 else 'status'
    try:
        if cmd=='status':r=status()
        elif cmd=='auto-connect':r=set_autoconnect(sys.argv[2]=='1')
        elif cmd=='lockdown':r=apply_lockdown(sys.argv[2]=='1')
        elif cmd=='lockdown-apply':r=apply_lockdown(None)
        elif cmd=='app-direct-launch':r=launch_direct(sys.argv[2])
        else:r={'ok':False,'error':'unknown desktop feature command'}
    except Exception as e:r={'ok':False,'error':str(e)}
    print(json.dumps(r,ensure_ascii=False,indent=2));return 0 if r.get('ok') else 1
if __name__=='__main__':raise SystemExit(main())
