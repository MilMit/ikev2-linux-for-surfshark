#!/usr/bin/env python3
"""
MilMit Secure v0.1.2 Phase 1.2
Policy routing foundation.

This module does not silently change routes. It can snapshot current state,
apply a VPN routing table, and verify that default traffic follows the tunnel.
"""
import json, pathlib, subprocess, time, os

STATE=pathlib.Path('/run/milmit-surfshark/route-state.json')
TABLE=220
VPN_IF='milmitxfrm0'

def run(cmd):
    p=subprocess.run(cmd,text=True,capture_output=True)
    return {'code':p.returncode,'out':p.stdout.strip(),'err':p.stderr.strip()}

def snapshot():
    data={
      'time':int(time.time()),
      'routes':run(['ip','-4','route','show']),
      'rules':run(['ip','-4','rule','show']),
      'dns':run(['resolvectl','status'])
    }
    STATE.parent.mkdir(parents=True,exist_ok=True)
    STATE.write_text(json.dumps(data,indent=2))
    os.chmod(STATE,0o600)
    return data

def verify():
    route=run(['ip','-4','route','get','1.1.1.1'])['out']
    return {
      'tunnel_present': pathlib.Path('/sys/class/net/'+VPN_IF).exists(),
      'default_route_via_vpn': VPN_IF in route,
      'route':route,
      'policy_rules':run(['ip','-4','rule','show'])['out']
    }

def apply_table():
    if not pathlib.Path('/sys/class/net/'+VPN_IF).exists():
        return {'ok':False,'error':'VPN tunnel interface missing'}
    snapshot()
    commands=[
      ['ip','-4','route','replace','default','dev',VPN_IF,'table',str(TABLE)],
      ['ip','-4','rule','add','priority','1000','lookup',str(TABLE)]
    ]
    result=[]
    for c in commands:
        result.append(run(c))
    return {'ok':verify()['default_route_via_vpn'],'commands':result,'verify':verify()}

if __name__=='__main__':
    import sys
    cmd=sys.argv[1] if len(sys.argv)>1 else 'verify'
    print(json.dumps(apply_table() if cmd=='apply' else verify(),indent=2))
