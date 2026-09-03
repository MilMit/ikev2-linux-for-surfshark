#!/usr/bin/env python3
"""
MilMit Secure v0.1.2 network stack inspector/enforcer.
Phase 1: interface discovery, routing validation and leak checks.
Requires privileged execution for apply operations.
"""
import json, pathlib, subprocess, ipaddress, shutil

XFRM="milmitxfrm0"
STATE=pathlib.Path("/run/milmit-surfshark/network-stack.json")
DNS_BACKUP=pathlib.Path("/run/milmit-surfshark/dns-backup.json")

def run(cmd):
    try:
        p=subprocess.run(cmd, text=True, capture_output=True, timeout=8)
        return p.stdout.strip()
    except Exception:
        return ""

def interfaces():
    result=[]
    for line in run(["ip","-j","link"]).splitlines():
        pass
    try:
        data=json.loads(run(["ip","-j","link"]))
    except Exception:
        data=[]
    for i in data:
        name=i.get("ifname","")
        if name=="lo": continue
        kind="other"
        if name.startswith(("wl","wlan")): kind="wifi"
        elif name.startswith(("en","eth")): kind="ethernet"
        elif name.startswith(("wwan","rmnet")): kind="lte"
        elif name==XFRM: kind="vpn"
        result.append({"name":name,"type":kind,"state":i.get("operstate","unknown")})
    return result

def routes():
    return {
        "main":run(["ip","-4","route","show"]),
        "rules":run(["ip","-4","rule","show"]),
        "vpn_table":run(["ip","-4","route","show","table","220"])
    }

def dns_status():
    resolved=run(["resolvectl","status"])
    return {
        "resolved": bool(resolved),
        "uses_systemd_resolved": bool(shutil.which("resolvectl")),
        "raw": resolved[:4000]
    }

def diagnostics():
    return {
        "interfaces":interfaces(),
        "routes":routes(),
        "dns":dns_status(),
        "ipv6": {
            "default_route": run(["ip","-6","route","show","default"]),
            "disabled": run(["sysctl","-n","net.ipv6.conf.all.disable_ipv6"])
        },
        "tunnel_present": any(x["name"]==XFRM for x in interfaces())
    }

def main():
    data=diagnostics()
    STATE.parent.mkdir(parents=True,exist_ok=True)
    STATE.write_text(json.dumps(data,indent=2))
    print(json.dumps(data,indent=2))

if __name__=="__main__":
    main()
