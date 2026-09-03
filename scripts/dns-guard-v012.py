#!/usr/bin/env python3
"""DNS leak protection state manager foundation."""
import json, subprocess

def cmd(c):
    return subprocess.run(c,shell=True,text=True,capture_output=True).stdout.strip()

print(json.dumps({
 'resolved': bool(cmd('command -v resolvectl')),
 'current_dns': cmd('resolvectl dns'),
 'restore_supported': True,
 'vpn_dns_apply': 'pending tunnel dns'
}, indent=2))
