#!/usr/bin/env python3
"""MilMit Secure v0.1.2 firewall guard foundation."""
import json, subprocess, sys

VPN_IF='milmitxfrm0'
CHAIN='MILMIT_KILLSWITCH'

def run(cmd):
    return subprocess.run(cmd, shell=True, text=True, capture_output=True).stdout.strip()

def status():
    return {
        'chain': CHAIN,
        'vpn_interface': VPN_IF,
        'mode': 'guard-ready',
        'iptables_available': bool(run('command -v iptables'))
    }

if __name__=='__main__':
    print(json.dumps(status(), indent=2))
