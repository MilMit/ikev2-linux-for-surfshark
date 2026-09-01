#!/usr/bin/env python3
import json, os, re, subprocess
from pathlib import Path
try:
 import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk, GLib
except Exception as exc: raise SystemExit(f'GTK3 is required: {exc}')
HELPER='/usr/libexec/milmit-surfshark-helper'; STATE=Path('/run/milmit-surfshark/restricted.state')
def run(args,timeout=30):
 try:
  p=subprocess.run(args,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout,check=False); return p.returncode,p.stdout.strip()
 except Exception as e:return 124,str(e)
def helper(*a): return run(['pkexec',HELPER,*a])
def jhelper(*a):
 rc,t=helper(*a)
 try:return rc,json.loads(t)
 except Exception:return rc,{'ok':False,'error':t}
class DeviceRow(Gtk.ListBoxRow):
 def __init__(self,d,s):
  super().__init__(); self.mac=d['mac']; box=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=8); box.set_border_width(12); self.add(box)
  top=Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL,spacing=8); txt=Gtk.Label(label=f"{d.get('ip','')}  ·  {self.mac}  ·  {d.get('state','')}"); txt.set_xalign(0); top.pack_start(txt,True,True,0)
  self.policy=Gtk.ComboBoxText(); [(self.policy.append(k,l)) for k,l in [('default','Default'),('vpn','Force VPN'),('direct','Direct'),('block','Block')]]; self.policy.set_active_id(s.get('policy','default')); top.pack_end(self.policy,False,False,0); box.pack_start(top,False,False,0)
  grid=Gtk.Grid(column_spacing=10,row_spacing=4); self.speed=Gtk.SpinButton.new_with_range(0,1000000,128); self.speed.set_value(int(s.get('speed_kbit',0) or 0)); self.quota=Gtk.SpinButton.new_with_range(0,100000,100); self.quota.set_value(int(s.get('quota_mb',0) or 0)); self.action=Gtk.ComboBoxText(); [(self.action.append(k,l)) for k,l in [('notify','Notify'),('throttle','Throttle'),('block','Block')]]; self.action.set_active_id(s.get('quota_action','notify')); self.pause=Gtk.Switch(); self.pause.set_active(bool(s.get('paused',False)))
  for i,(lab,w) in enumerate([('Speed kbit/s',self.speed),('Daily quota MB',self.quota),('Quota action',self.action),('Pause',self.pause)]):
   v=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=2); x=Gtk.Label(label=lab); x.set_xalign(0); v.pack_start(x,False,False,0); v.pack_start(w,False,False,0); grid.attach(v,i,0,1,1)
  box.pack_start(grid,False,False,0)
 def values(self): return [self.mac,self.policy.get_active_id() or 'default',str(self.speed.get_value_as_int()),str(self.quota.get_value_as_int()),self.action.get_active_id() or 'notify','1' if self.pause.get_active() else '0']
class Manager(Gtk.Window):
 def __init__(self):
  super().__init__(title='MilMit Secure · Hotspot Control Center'); self.set_default_size(940,700); self.set_border_width(18); self.rows=[]
  root=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=12); self.add(root); title=Gtk.Label(); title.set_markup("<span size='xx-large' weight='bold'>Hotspot Control Center</span>"); title.set_xalign(0); root.pack_start(title,False,False,0)
  self.note=Gtk.Label(label='Per-device VPN/Direct/Block, quota, speed limits, Guest Hotspot, DNS/QUIC/IPv6 protection'); self.note.set_xalign(0); root.pack_start(self.note,False,False,0)
  nb=Gtk.Notebook(); root.pack_start(nb,True,True,0)
  dev=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=8); self.listbox=Gtk.ListBox(); self.listbox.set_selection_mode(Gtk.SelectionMode.NONE); sc=Gtk.ScrolledWindow(); sc.add(self.listbox); dev.pack_start(sc,True,True,0); bar=Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL,spacing=8); refresh=Gtk.Button(label='Refresh'); repair=Gtk.Button(label='Repair hotspot'); apply=Gtk.Button(label='Apply device policies'); apply.get_style_context().add_class('suggested-action'); bar.pack_start(refresh,False,False,0); bar.pack_start(repair,False,False,0); bar.pack_end(apply,False,False,0); dev.pack_start(bar,False,False,0); nb.append_page(dev,Gtk.Label(label='Devices'))
  sec=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=12); sec.set_border_width(16); self.force_dns=Gtk.CheckButton(label='Force protected DNS for hotspot'); self.quic=Gtk.CheckButton(label='Block QUIC (UDP/443)'); self.isolation=Gtk.CheckButton(label='Client isolation'); self.ipv6=Gtk.ComboBoxText(); self.ipv6.append('block','Block IPv6'); self.ipv6.append('allow','Allow IPv6'); self.ipv6.set_active_id('block'); sec.pack_start(self.force_dns,False,False,0); sec.pack_start(self.quic,False,False,0); sec.pack_start(self.isolation,False,False,0); sec.pack_start(self.ipv6,False,False,0); sec_apply=Gtk.Button(label='Apply protection'); sec_apply.get_style_context().add_class('suggested-action'); sec.pack_start(sec_apply,False,False,0); nb.append_page(sec,Gtk.Label(label='Protection'))
  guest=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=8); guest.set_border_width(16); self.ssid=Gtk.Entry(); self.ssid.set_text('MilMit Guest'); self.minutes=Gtk.SpinButton.new_with_range(5,1440,5); self.minutes.set_value(60); guest.pack_start(Gtk.Label(label='Guest SSID'),False,False,0); guest.pack_start(self.ssid,False,False,0); guest.pack_start(Gtk.Label(label='Duration (minutes)'),False,False,0); guest.pack_start(self.minutes,False,False,0); gb=Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL,spacing=8); gs=Gtk.Button(label='Start Guest'); gs.get_style_context().add_class('suggested-action'); ge=Gtk.Button(label='Stop Guest'); gb.pack_start(gs,False,False,0); gb.pack_start(ge,False,False,0); guest.pack_start(gb,False,False,0); nb.append_page(guest,Gtk.Label(label='Guest Hotspot'))
  pol=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=8); pol.set_border_width(16); self.target=Gtk.Entry(); self.target.set_placeholder_text('domain / IPv4 / CIDR'); self.rule=Gtk.ComboBoxText(); [(self.rule.append(k,l)) for k,l in [('vpn','Force VPN'),('direct','Direct'),('block','Block')]]; self.rule.set_active_id('vpn'); self.scope=Gtk.ComboBoxText(); [(self.scope.append(k,l)) for k,l in [('both','Ubuntu + Hotspot'),('ubuntu','Ubuntu only'),('hotspot','Hotspot only')]]; self.scope.set_active_id('both'); pb=Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL,spacing=8); pb.pack_start(self.target,True,True,0); pb.pack_start(self.rule,False,False,0); pb.pack_start(self.scope,False,False,0); pa=Gtk.Button(label='Add / Update'); pb.pack_start(pa,False,False,0); pol.pack_start(pb,False,False,0); self.policy_text=Gtk.TextView(); self.policy_text.set_editable(False); self.policy_text.set_monospace(True); ps=Gtk.ScrolledWindow(); ps.add(self.policy_text); pol.pack_start(ps,True,True,0); nb.append_page(pol,Gtk.Label(label='Domain/IP Rules'))
  self.status=Gtk.Label(label='Loading…'); self.status.set_xalign(0); root.pack_start(self.status,False,False,0)
  refresh.connect('clicked',lambda *_:self.reload()); repair.connect('clicked',lambda *_:self.action('hotspot-repair')); apply.connect('clicked',lambda *_:self.apply_devices()); sec_apply.connect('clicked',lambda *_:self.apply_options()); gs.connect('clicked',lambda *_:self.start_guest()); ge.connect('clicked',lambda *_:self.action('guest-stop')); pa.connect('clicked',lambda *_:self.add_policy()); self.reload(); GLib.timeout_add_seconds(5,self.tick)
 def tick(self): self.reload(True); return True
 def reload(self,quiet=False):
  rc,d=jhelper('router-status'); h=d.get('hotspot',{}); c=d.get('config',{}); stored=c.get('devices',{}); [self.listbox.remove(x) for x in self.listbox.get_children()]; self.rows=[]
  for x in h.get('clients',[]): r=DeviceRow(x,stored.get(x.get('mac',''),{})); self.rows.append(r); self.listbox.add(r)
  if not self.rows:
   r=Gtk.ListBoxRow(); l=Gtk.Label(label='No hotspot clients detected. Connect the phone and press Refresh.'); l.set_margin_top(24); l.set_margin_bottom(24); r.add(l); self.listbox.add(r)
  self.listbox.show_all(); self.force_dns.set_active(bool(c.get('force_dns',True))); self.quic.set_active(bool(c.get('block_quic',False))); self.isolation.set_active(bool(c.get('client_isolation',False))); self.ipv6.set_active_id(c.get('ipv6_policy','block')); self.policy_text.get_buffer().set_text(json.dumps(c.get('policies',[]),ensure_ascii=False,indent=2)); self.status.set_text(f"Hotspot: {h.get('iface') or 'not detected'} · {h.get('subnet') or '—'} · {h.get('client_count',0)} client(s)")
 def dialog(self,t,m): d=Gtk.MessageDialog(transient_for=self,flags=0,message_type=Gtk.MessageType.INFO,buttons=Gtk.ButtonsType.OK,text=t); d.format_secondary_text((m or '')[:5000]); d.run(); d.destroy()
 def action(self,*a): rc,t=helper(*a); self.dialog('Operation result',t or ('OK' if rc==0 else 'Failed')); self.reload()
 def apply_devices(self):
  out=[]
  for r in self.rows: out.append(helper('device-set',*r.values())[1])
  self.dialog('Device policies','\n'.join(out) or 'No devices'); self.reload()
 def apply_options(self): self.action('router-options','1' if self.force_dns.get_active() else '0','1' if self.quic.get_active() else '0','1' if self.isolation.get_active() else '0',self.ipv6.get_active_id() or 'block')
 def start_guest(self):
  rc,d=jhelper('guest-start',str(self.minutes.get_value_as_int()),self.ssid.get_text().strip() or 'MilMit Guest'); self.dialog('Guest Hotspot',f"SSID: {d.get('ssid','')}\nPassword: {d.get('password','')}\n{d.get('wifi_uri','')}" if d.get('ok') else d.get('error','Failed'))
 def add_policy(self):
  t=self.target.get_text().strip()
  if t:self.action('policy-add',t,self.rule.get_active_id() or 'vpn',self.scope.get_active_id() or 'both')
if __name__=='__main__': w=Manager(); w.connect('destroy',Gtk.main_quit); w.show_all(); Gtk.main()
