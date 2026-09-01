#!/usr/bin/env python3
import hashlib, ipaddress, json, os, pathlib, shutil, subprocess, tempfile, time

ROOT = pathlib.Path('/var/lib/milmit-surfshark/rules')
META = ROOT / 'metadata.json'
SOURCES = {
    'ircidr.txt': [
        'https://raw.githubusercontent.com/Chocolate4U/Iran-clash-rules/release/ircidr.txt',
        'https://cdn.jsdelivr.net/gh/Chocolate4U/Iran-clash-rules@release/ircidr.txt',
    ],
    'ir-lite.txt': [
        'https://raw.githubusercontent.com/Chocolate4U/Iran-clash-rules/release/ir-lite.txt',
        'https://cdn.jsdelivr.net/gh/Chocolate4U/Iran-clash-rules@release/ir-lite.txt',
    ],
    'geoip-lite.dat': [
        'https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geoip-lite.dat',
        'https://cdn.jsdelivr.net/gh/Chocolate4U/Iran-v2ray-rules@release/geoip-lite.dat',
    ],
    'geosite-lite.dat': [
        'https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geosite-lite.dat',
        'https://cdn.jsdelivr.net/gh/Chocolate4U/Iran-v2ray-rules@release/geosite-lite.dat',
    ],
    'geoip-lite.dat.sha256sum': [
        'https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geoip-lite.dat.sha256sum',
        'https://cdn.jsdelivr.net/gh/Chocolate4U/Iran-v2ray-rules@release/geoip-lite.dat.sha256sum',
    ],
    'geosite-lite.dat.sha256sum': [
        'https://raw.githubusercontent.com/Chocolate4U/Iran-v2ray-rules/release/geosite-lite.dat.sha256sum',
        'https://cdn.jsdelivr.net/gh/Chocolate4U/Iran-v2ray-rules@release/geosite-lite.dat.sha256sum',
    ],
}

def run(args, timeout=30):
    try:
        p = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        return p.returncode, (p.stdout + ('\n' if p.stdout and p.stderr else '') + p.stderr).strip()
    except Exception as e:
        return 124, str(e)

def download(urls, out):
    last = ''
    for url in urls:
        rc, text = run(['curl','-4','-fL','--connect-timeout','8','--max-time','35','--retry','1','-sS','-o',str(out),url], 40)
        if rc == 0 and out.exists() and out.stat().st_size > 0:
            return url
        last = text
    raise RuntimeError(last or 'all rule mirrors failed')

def validate_cidrs(path):
    rows=[]
    for raw in path.read_text(errors='replace').splitlines():
        s=raw.strip()
        if not s or s.startswith('#'): continue
        try:
            n=ipaddress.ip_network(s, strict=False)
            if n.version==4: rows.append(str(n))
        except ValueError: pass
    if len(rows) < 100:
        raise RuntimeError(f'CIDR validation failed: only {len(rows)} usable prefixes')
    return sorted(set(rows))

def validate_domains(path):
    rows=[]
    for raw in path.read_text(errors='replace').splitlines():
        s=raw.strip().lower()
        if not s or s.startswith('#'): continue
        s=s.removeprefix('+.').removeprefix('domain:').strip('.')
        if '.' in s and ' ' not in s and '/' not in s: rows.append(s)
    if len(rows) < 100:
        raise RuntimeError(f'domain validation failed: only {len(rows)} usable domains')
    return sorted(set(rows))

def sha256(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()

def expected_sha(path):
    text=path.read_text(errors='replace').strip().split()
    return text[0].lower() if text else ''

def update(force=False):
    ROOT.mkdir(parents=True, exist_ok=True)
    old={}
    try: old=json.loads(META.read_text())
    except Exception: pass
    if not force and old.get('updated_at',0) > time.time()-6*24*3600 and (ROOT/'ircidr.txt').exists() and (ROOT/'ir-lite.txt').exists():
        return {'ok':True,'state':'fresh','network_used':False,**old}
    with tempfile.TemporaryDirectory(prefix='milmit-rules-') as td:
        t=pathlib.Path(td); mirrors={}
        for name,urls in SOURCES.items(): mirrors[name]=download(urls,t/name)
        cidrs=validate_cidrs(t/'ircidr.txt'); domains=validate_domains(t/'ir-lite.txt')
        for dat in ('geoip-lite.dat','geosite-lite.dat'):
            if (t/dat).stat().st_size < 10000: raise RuntimeError(f'{dat} suspiciously small')
            want=expected_sha(t/(dat+'.sha256sum'))
            if want and sha256(t/dat).lower()!=want: raise RuntimeError(f'{dat} SHA-256 mismatch')
        # Atomic-ish replacement: copy each validated artifact to temp sibling then rename.
        for name in SOURCES:
            tmp=ROOT/(name+'.new'); shutil.copy2(t/name,tmp); os.chmod(tmp,0o644); tmp.replace(ROOT/name)
        # Hot-path normalized files used by native router.
        (ROOT/'iran-ipv4.txt.new').write_text('\n'.join(cidrs)+'\n'); (ROOT/'iran-ipv4.txt.new').replace(ROOT/'iran-ipv4.txt')
        (ROOT/'iran-domains.txt.new').write_text('\n'.join(domains)+'\n'); (ROOT/'iran-domains.txt.new').replace(ROOT/'iran-domains.txt')
        # Backward-compatible path used by connector.
        target=pathlib.Path('/var/lib/milmit-surfshark/iran-ipv4.txt')
        shutil.copy2(ROOT/'iran-ipv4.txt',target); os.chmod(target,0o644)
        meta={'updated_at':int(time.time()),'source':'Chocolate4U local snapshot','cidr_count':len(cidrs),'domain_count':len(domains),'mirrors':mirrors}
        tmp=ROOT/'metadata.json.new'; tmp.write_text(json.dumps(meta,indent=2)); os.chmod(tmp,0o644); tmp.replace(META)
        return {'ok':True,'state':'updated','network_used':True,**meta}

def status():
    try: meta=json.loads(META.read_text())
    except Exception: meta={}
    return {'ok':True,'present':(ROOT/'ircidr.txt').exists() and (ROOT/'ir-lite.txt').exists(),'metadata':meta,'path':str(ROOT)}

if __name__=='__main__':
    if os.geteuid()!=0:
        print(json.dumps({'ok':False,'error':'rules updater must run as root'})); raise SystemExit(77)
    cmd=os.sys.argv[1] if len(os.sys.argv)>1 else 'status'
    try:
        result=status() if cmd=='status' else update(force=(cmd=='update-force')) if cmd in ('update','update-force') else {'ok':False,'error':'unknown command'}
    except Exception as e: result={'ok':False,'error':str(e)}
    print(json.dumps(result,ensure_ascii=False,indent=2)); raise SystemExit(0 if result.get('ok') else 1)
