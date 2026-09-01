#!/usr/bin/env python3
import html, json, pathlib, subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE=pathlib.Path('/run/milmit-surfshark/restricted.state')
LIVE=pathlib.Path('/run/milmit-surfshark/live.state')
ROUTER='/usr/libexec/milmit-surfshark-helper'

def kv(p):
    d={}
    try:
        for l in p.read_text(errors='replace').splitlines():
            if '=' in l:
                k,v=l.split('=',1);d[k]=v
    except OSError:pass
    return d

def helper(*args):
    try:
        p=subprocess.run([ROUTER,*args],capture_output=True,text=True,timeout=8)
        return json.loads(p.stdout or '{}')
    except Exception:return {}

def page():
    st,lv=kv(STATE),kv(LIVE);r=helper('router-status');g=r.get('guest',{});hs=r.get('hotspot',{})
    ip=html.escape(st.get('PUBLIC_IP','—'));country=html.escape(st.get('EXIT_COUNTRY','—'));health=html.escape(lv.get('HEALTH','UNKNOWN'));lat=html.escape(lv.get('LATENCY_MS','0'))
    clients=hs.get('clients',[]);rows=''.join(f"<tr><td>{html.escape(x.get('ip',''))}</td><td>{html.escape(x.get('mac',''))}</td><td>{html.escape(x.get('state',''))}</td></tr>" for x in clients) or '<tr><td colspan=3>No clients</td></tr>'
    guest='Active' if g.get('active') else 'Off'
    return f'''<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><title>MilMit Secure</title><style>body{{font-family:system-ui;background:#0b0d12;color:#eef2ff;margin:0;padding:24px}}.wrap{{max-width:860px;margin:auto}}.card{{background:#151925;border:1px solid #2b3245;border-radius:20px;padding:18px;margin:12px 0}}h1{{margin:0 0 6px}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}}.v{{font-size:22px;font-weight:800}}.k{{opacity:.65;font-size:12px}}table{{width:100%;border-collapse:collapse}}td,th{{padding:9px;border-bottom:1px solid #2b3245;text-align:left}}.ok{{color:#71e6a3}}</style><div class=wrap><h1>MilMit Secure</h1><div class=k>Local protection status portal</div><div class="card grid"><div><div class=v>{ip}</div><div class=k>Public IP</div></div><div><div class=v>{country}</div><div class=k>Exit</div></div><div><div class="v ok">{health}</div><div class=k>Health</div></div><div><div class=v>{lat} ms</div><div class=k>Latency</div></div><div><div class=v>{html.escape(st.get('ROUTING_MODE','—'))}</div><div class=k>Routing</div></div><div><div class=v>{guest}</div><div class=k>Guest</div></div></div><div class=card><h3>Hotspot clients</h3><table><tr><th>IP</th><th>MAC</th><th>State</th></tr>{rows}</table></div><div class=card><div class=k>DNS</div><div>{html.escape(st.get('DNS_CSV','—'))}</div><div class=k style="margin-top:12px">Virtual IP</div><div>{html.escape(st.get('VIRTUAL_IP','—'))}</div></div></div>'''

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ('/','/status'):
            self.send_response(404);self.end_headers();return
        b=page().encode();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(b)));self.end_headers();self.wfile.write(b)
    def log_message(self,*a):pass

if __name__=='__main__':ThreadingHTTPServer(('0.0.0.0',8787),H).serve_forever()
