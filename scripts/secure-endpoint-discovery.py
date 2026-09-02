#!/usr/bin/env python3
import ipaddress, json, os, random, re, socket, ssl, struct, subprocess, sys, time

CACHE='/var/lib/milmit-surfshark/endpoint-cache.json'
CACHE_MAX_AGE=48*60*60
DOH=(
 ('cloudflare','cloudflare-dns.com','1.1.1.1','/dns-query'),
 ('cloudflare2','cloudflare-dns.com','1.0.0.1','/dns-query'),
 ('google','dns.google','8.8.8.8','/resolve'),
 ('google2','dns.google','8.8.4.4','/resolve'),
 ('quad9','dns.quad9.net','9.9.9.9','/dns-query'),
 ('quad92','dns.quad9.net','149.112.112.112','/dns-query'),
 ('adguard','dns.adguard-dns.com','94.140.14.14','/resolve'),
 ('adguard2','dns.adguard-dns.com','94.140.15.15','/resolve'),
)
DOT=(
 ('cloudflare-dot','cloudflare-dns.com','1.1.1.1'),
 ('google-dot','dns.google','8.8.8.8'),
 ('quad9-dot','dns.quad9.net','9.9.9.9'),
 ('adguard-dot','dns.adguard-dns.com','94.140.14.14'),
)

def public4(x):
 try:
  ip=ipaddress.ip_address(str(x));return ip.version==4 and not(ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified)
 except ValueError:return False

def uniq(xs):
 out=[]
 for x in xs:
  x=str(x).strip()
  if public4(x) and x not in out:out.append(x)
 return out

def load_cache(identity):
 try:
  data=json.load(open(CACHE));row=(data.get('locations')or{}).get(identity)or{}
  if int(time.time())-int(row.get('updated_unix',0))>CACHE_MAX_AGE:return []
  return uniq(row.get('addresses')or[])
 except Exception:return []

def parse_json(text):
 try:data=json.loads(text)
 except Exception:return []
 out=[]
 for r in data.get('Answer')or[]:
  if int(r.get('type',0))==1 and public4(r.get('data','')):out.append(r['data'])
 return uniq(out)

def doh(identity):
 found=[];src=[]
 for name,host,ip,path in DOH:
  url=f'https://{host}{path}?name={identity}&type=A'
  try:
   p=subprocess.run(['curl','-4','-fsS','--connect-timeout','1','--max-time','2','--resolve',f'{host}:443:{ip}','-H','accept: application/dns-json',url],text=True,capture_output=True,timeout=3)
  except Exception:continue
  if p.returncode:continue
  ans=parse_json(p.stdout)
  if ans:
   src.append(name);found=uniq(found+ans)
  if len(src)>=2:break
 return found,src

def qname(name):
 out=b''
 for part in name.rstrip('.').split('.'):
  b=part.encode('ascii');out+=bytes([len(b)])+b
 return out+b'\x00'

def build_query(name):
 qid=random.randint(0,65535)
 hdr=struct.pack('!HHHHHH',qid,0x0100,1,0,0,0)
 return qid,hdr+qname(name)+struct.pack('!HH',1,1)

def skip_name(buf,off):
 while True:
  n=buf[off]
  if n&0xC0==0xC0:return off+2
  off+=1
  if n==0:return off
  off+=n

def parse_dns(buf,qid):
 if len(buf)<12:return []
 rid,flags,qd,an,_,_=struct.unpack('!HHHHHH',buf[:12])
 if rid!=qid or flags&0x000F:return []
 off=12
 for _ in range(qd):off=skip_name(buf,off)+4
 out=[]
 for _ in range(an):
  off=skip_name(buf,off)
  if off+10>len(buf):break
  typ,cls,ttl,rdlen=struct.unpack('!HHIH',buf[off:off+10]);off+=10
  r=buf[off:off+rdlen];off+=rdlen
  if typ==1 and cls==1 and rdlen==4:out.append(socket.inet_ntoa(r))
 return uniq(out)

def dot_query(identity,host,ip):
 qid,payload=build_query(identity)
 ctx=ssl.create_default_context()
 try:
  with socket.create_connection((ip,853),timeout=1.8) as raw:
   with ctx.wrap_socket(raw,server_hostname=host) as s:
    s.settimeout(1.8);s.sendall(struct.pack('!H',len(payload))+payload)
    head=s.recv(2)
    if len(head)!=2:return []
    need=struct.unpack('!H',head)[0];buf=b''
    while len(buf)<need:
     c=s.recv(need-len(buf))
     if not c:break
     buf+=c
    return parse_dns(buf,qid)
 except Exception:return []

def dot(identity):
 found=[];src=[]
 for name,host,ip in DOT:
  ans=dot_query(identity,host,ip)
  if ans:
   src.append(name);found=uniq(found+ans)
  if len(src)>=2:break
 return found,src

def main():
 if len(sys.argv)<2:return 64
 identity=sys.argv[1]
 if not re.fullmatch(r'[A-Za-z0-9.-]+\.prod\.surfshark\.com',identity):return 64
 bootstrap=[]
 if len(sys.argv)>2:bootstrap=uniq(sys.argv[2].split(','))
 fresh,src=doh(identity)
 if len(src)<2:
  d,ds=dot(identity);fresh=uniq(fresh+d);src+=ds
 cached=load_cache(identity)
 merged=uniq(fresh+cached+bootstrap)[:32]
 print(json.dumps({'identity':identity,'addresses':merged,'fresh':fresh,'sources':src,'cached':cached,'bootstrap':bootstrap},separators=(',',':')))
 return 0 if merged else 69

if __name__=='__main__':raise SystemExit(main())
