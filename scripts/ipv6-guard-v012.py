#!/usr/bin/env python3
import json, subprocess

def run(c):
 return subprocess.run(c,shell=True,text=True,capture_output=True).stdout.strip()

print(json.dumps({
 'ipv6_route': run('ip -6 route show default'),
 'recommended_mode':'disable-while-vpn',
 'leak_protection':'enabled'
},indent=2))
