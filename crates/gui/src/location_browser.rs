use adw::prelude::*;
use gtk::{glib, Orientation};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::rc::Rc;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use crate::bundled_endpoints::for_host as bundled_for_host;
use crate::locations::{by_id, LOCATIONS};

fn cfg_dir() -> PathBuf {
    std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|_| std::env::var("HOME").map(|h| PathBuf::from(h).join(".config")))
        .unwrap_or_else(|_| PathBuf::from("."))
        .join("milmit-surfshark")
}
fn favorites_path() -> PathBuf { cfg_dir().join("favorites.conf") }
fn recents_path() -> PathBuf { cfg_dir().join("recent-locations.conf") }
fn read_lines(path: PathBuf) -> Vec<String> {
    fs::read_to_string(path).unwrap_or_default().lines().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string).collect()
}
fn write_lines(path: PathBuf, items: impl IntoIterator<Item=String>) {
    if let Some(parent) = path.parent() { let _ = fs::create_dir_all(parent); }
    let text = items.into_iter().collect::<Vec<_>>().join("\n");
    let _ = fs::write(path, if text.is_empty() { text } else { format!("{text}\n") });
}
fn ping_target(host: &str) -> String {
    if host == "ee-tll.prod.surfshark.com" { return "185.174.159.123".into(); }
    bundled_for_host(host).first().copied().unwrap_or(host).to_string()
}
fn ping_ms(host: &str) -> Option<u32> {
    let target = ping_target(host);
    let out = Command::new("ping").args(["-n","-c","1","-W","1",&target]).output().ok()?;
    if !out.status.success() { return None; }
    let text = String::from_utf8_lossy(&out.stdout);
    let pos = text.find("time=")? + 5;
    let rest = &text[pos..];
    let end = rest.find(|c: char| c == ' ' || c == '\n').unwrap_or(rest.len());
    rest[..end].parse::<f64>().ok().map(|v| v.round() as u32)
}
fn ping_text(ms: Option<u32>) -> String { ms.map(|v| format!("{v} ms")).unwrap_or_else(|| "—".into()) }

#[derive(Clone)]
struct RowParts { ping: gtk::Label, root: gtk::ListBoxRow, star: gtk::Button }

fn add_recent(id: &str) {
    let mut q = VecDeque::from(read_lines(recents_path()));
    q.retain(|v| v != id);
    q.push_front(id.to_string());
    while q.len() > 8 { q.pop_back(); }
    write_lines(recents_path(), q);
}

fn set_favorite(id: &str, on: bool) {
    let mut set: HashSet<String> = read_lines(favorites_path()).into_iter().collect();
    if on { set.insert(id.to_string()); } else { set.remove(id); }
    let mut v = set.into_iter().collect::<Vec<_>>();
    v.sort();
    write_lines(favorites_path(), v);
}

fn location_row(
    id: &'static str,
    country: &'static str,
    city: &'static str,
    host: &'static str,
    selected: Rc<RefCell<String>>,
    home_label: gtk::Label,
    stack: gtk::Stack,
    favorites: Rc<RefCell<HashSet<String>>>,
) -> (gtk::ListBoxRow, gtk::Label, gtk::Button) {
    let row = gtk::ListBoxRow::new();
    let box_ = gtk::Box::new(Orientation::Horizontal, 8);
    box_.add_css_class("location-city-row");
    let choose = gtk::Button::new();
    choose.add_css_class("flat-location");
    choose.set_hexpand(true);
    let inner = gtk::Box::new(Orientation::Vertical, 1);
    inner.append(&gtk::Label::builder().label(city).halign(gtk::Align::Start).css_classes(["row-title"]).build());
    inner.append(&gtk::Label::builder().label(host).halign(gtk::Align::Start).ellipsize(gtk::pango::EllipsizeMode::Middle).css_classes(["row-sub"]).build());
    choose.set_child(Some(&inner));
    let ping = gtk::Label::builder().label("…").width_chars(7).halign(gtk::Align::End).css_classes(["ping-badge"]).build();
    let star = gtk::Button::with_label(if favorites.borrow().contains(id) { "★" } else { "☆" });
    star.add_css_class("star-button");
    let id_s = id.to_string();
    let label = format!("{} · {}", country, city);
    let sel = selected.clone(); let ll = home_label.clone(); let st = stack.clone();
    choose.connect_clicked(move |_| { *sel.borrow_mut() = id_s.clone(); add_recent(&id_s); ll.set_label(&label); st.set_visible_child_name("home"); });
    let favs = favorites.clone(); let sid = id.to_string(); let star_clone = star.clone();
    star.connect_clicked(move |_| { let now = !favs.borrow().contains(&sid); if now { favs.borrow_mut().insert(sid.clone()); } else { favs.borrow_mut().remove(&sid); } set_favorite(&sid, now); star_clone.set_label(if now { "★" } else { "☆" }); });

    // Right-click context actions: select, ping now, favorite and copy hostname.
    let gesture = gtk::GestureClick::new(); gesture.set_button(3);
    let host_s = host.to_string(); let id_ctx = id.to_string(); let country_s = country.to_string(); let city_s = city.to_string();
    let ping_ctx = ping.clone(); let favs_ctx = favorites.clone(); let ll_ctx = home_label.clone(); let st_ctx = stack.clone(); let sel_ctx = selected.clone(); let star_ctx = star.clone();
    gesture.connect_pressed(move |g,_,x,y| {
        let pop = gtk::Popover::new();
        let Some(widget) = g.widget() else { return; };
        pop.set_parent(&widget);
        pop.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32,y as i32,1,1)));
        let menu = gtk::Box::new(Orientation::Vertical,4); menu.set_margin_top(6); menu.set_margin_bottom(6); menu.set_margin_start(6); menu.set_margin_end(6);
        let select_b = gtk::Button::with_label("Select location");
        let ping_b = gtk::Button::with_label("Ping now");
        let fav_b = gtk::Button::with_label(if favs_ctx.borrow().contains(&id_ctx) { "Remove favorite" } else { "Add favorite" });
        let copy_b = gtk::Button::with_label("Copy hostname");
        for b in [&select_b,&ping_b,&fav_b,&copy_b] { b.add_css_class("context-button"); menu.append(b); }
        let id1=id_ctx.clone(); let label1=format!("{} · {}",country_s,city_s); let sel1=sel_ctx.clone(); let ll1=ll_ctx.clone(); let st1=st_ctx.clone(); let p1=pop.clone();
        select_b.connect_clicked(move |_| { *sel1.borrow_mut()=id1.clone(); add_recent(&id1); ll1.set_label(&label1); p1.popdown(); st1.set_visible_child_name("home"); });
        let h1=host_s.clone(); let pl=ping_ctx.clone(); let p2=pop.clone();
        ping_b.connect_clicked(move |_| { pl.set_label("…"); let (tx,rx)=mpsc::channel(); let h=h1.clone(); thread::spawn(move || { let _=tx.send(ping_ms(&h)); }); let pl2=pl.clone(); glib::timeout_add_local(Duration::from_millis(80), move || match rx.try_recv(){Ok(v)=>{pl2.set_label(&ping_text(v));glib::ControlFlow::Break},Err(mpsc::TryRecvError::Empty)=>glib::ControlFlow::Continue,Err(_)=>glib::ControlFlow::Break}); p2.popdown(); });
        let favs2=favs_ctx.clone(); let sid=id_ctx.clone(); let sbtn=star_ctx.clone(); let p3=pop.clone();
        fav_b.connect_clicked(move |_| { let now=!favs2.borrow().contains(&sid); if now{favs2.borrow_mut().insert(sid.clone());}else{favs2.borrow_mut().remove(&sid);} set_favorite(&sid,now); sbtn.set_label(if now{"★"}else{"☆"}); p3.popdown(); });
        let hc=host_s.clone(); let p4=pop.clone(); copy_b.connect_clicked(move |_| { if let Some(d)=gtk::gdk::Display::default(){d.clipboard().set_text(&hc);} p4.popdown(); });
        pop.set_child(Some(&menu)); pop.popup();
    });
    box_.add_controller(gesture);
    box_.append(&choose); box_.append(&ping); box_.append(&star);
    row.set_child(Some(&box_));
    (row,ping,star)
}

pub fn build(
    stack: &gtk::Stack,
    selected: Rc<RefCell<String>>,
    home_label: &gtk::Label,
) -> gtk::Box {
    let page = gtk::Box::new(Orientation::Vertical, 0);
    let top = gtk::Box::new(Orientation::Horizontal, 8); top.add_css_class("top");
    let back=gtk::Button::from_icon_name("go-previous-symbolic"); back.add_css_class("back"); let st=stack.clone(); back.connect_clicked(move |_|st.set_visible_child_name("home")); top.append(&back);
    top.append(&gtk::Label::builder().label("Select location").hexpand(true).halign(gtk::Align::Start).css_classes(["brand"]).build());
    let scan=gtk::Button::with_label("Scan all"); scan.add_css_class("back"); top.append(&scan); page.append(&top);

    let body=gtk::Box::new(Orientation::Vertical,10); body.add_css_class("page");
    let search=gtk::SearchEntry::builder().placeholder_text("Search country, city or hostname").build(); body.append(&search);
    let banner=adw::Banner::builder().title("Latency scan checks the bundled direct-IP endpoint for each location.").build(); banner.set_revealed(false); body.append(&banner);

    let favorites: Rc<RefCell<HashSet<String>>> = Rc::new(RefCell::new(read_lines(favorites_path()).into_iter().collect()));
    let recents=read_lines(recents_path());
    let rows: Rc<RefCell<HashMap<String,RowParts>>> = Rc::new(RefCell::new(HashMap::new()));
    let country_widgets: Rc<RefCell<Vec<(gtk::Expander,String)>>> = Rc::new(RefCell::new(Vec::new()));

    if !favorites.borrow().is_empty() {
        body.append(&gtk::Label::builder().label("FAVORITES").halign(gtk::Align::Start).css_classes(["section"]).build());
        let favbox=gtk::ListBox::new(); favbox.add_css_class("location-list"); favbox.set_selection_mode(gtk::SelectionMode::None);
        let ids=favorites.borrow().iter().cloned().collect::<Vec<_>>();
        for id in ids { if let Some(l)=by_id(&id) { let (r,p,s)=location_row(l.id,l.country,l.city,l.host,selected.clone(),home_label.clone(),stack.clone(),favorites.clone()); favbox.append(&r); rows.borrow_mut().insert(format!("fav:{}",l.id),RowParts{ping:p,root:r,star:s}); } }
        body.append(&favbox);
    }
    if !recents.is_empty() {
        body.append(&gtk::Label::builder().label("RECENT").halign(gtk::Align::Start).css_classes(["section"]).build());
        let recentbox=gtk::ListBox::new(); recentbox.add_css_class("location-list"); recentbox.set_selection_mode(gtk::SelectionMode::None);
        for id in recents { if let Some(l)=by_id(&id) { let (r,p,s)=location_row(l.id,l.country,l.city,l.host,selected.clone(),home_label.clone(),stack.clone(),favorites.clone()); recentbox.append(&r); rows.borrow_mut().insert(format!("recent:{}",l.id),RowParts{ping:p,root:r,star:s}); } }
        body.append(&recentbox);
    }

    body.append(&gtk::Label::builder().label("ALL LOCATIONS").halign(gtk::Align::Start).css_classes(["section"]).build());
    let mut countries:BTreeMap<&'static str,Vec<_>>=BTreeMap::new(); for l in LOCATIONS { countries.entry(l.country).or_default().push(l); }
    for (country, mut locs) in countries { locs.sort_by_key(|l|l.city); let exp=gtk::Expander::builder().label(country).build(); exp.add_css_class("country-expander"); let list=gtk::ListBox::new(); list.add_css_class("location-list"); list.set_selection_mode(gtk::SelectionMode::None); let mut search_blob=country.to_lowercase();
        for l in locs { search_blob.push(' '); search_blob.push_str(&format!("{} {}",l.city,l.host).to_lowercase()); let (r,p,s)=location_row(l.id,l.country,l.city,l.host,selected.clone(),home_label.clone(),stack.clone(),favorites.clone()); list.append(&r); rows.borrow_mut().insert(l.id.to_string(),RowParts{ping:p,root:r,star:s}); }
        exp.set_child(Some(&list)); body.append(&exp); country_widgets.borrow_mut().push((exp,search_blob));
    }

    let countries_filter=country_widgets.clone(); search.connect_search_changed(move |e| { let q=e.text().to_lowercase(); for (exp,blob) in countries_filter.borrow().iter(){ let show=q.is_empty()||blob.contains(&q); exp.set_visible(show); if !q.is_empty()&&show{exp.set_expanded(true);} } });

    let run_scan = {
        let rows=rows.clone(); let banner=banner.clone();
        move || {
            banner.set_title("Scanning location latency…"); banner.set_revealed(true);
            for parts in rows.borrow().values(){parts.ping.set_label("…");}
            let (tx,rx)=mpsc::channel::<(String,Option<u32>)>();
            thread::spawn(move || { for l in LOCATIONS { let _=tx.send((l.id.to_string(),ping_ms(l.host))); } });
            let rows2=rows.clone(); let banner2=banner.clone(); let mut completed=0usize; let total=LOCATIONS.len();
            glib::timeout_add_local(Duration::from_millis(45), move || { while let Ok((id,ms))=rx.try_recv(){ completed+=1; let text=ping_text(ms); for key in [id.clone(),format!("fav:{id}"),format!("recent:{id}")] { if let Some(parts)=rows2.borrow().get(&key){parts.ping.set_label(&text);} } } if completed>=total { banner2.set_title("Latency scan complete. Lower is better."); return glib::ControlFlow::Break; } glib::ControlFlow::Continue });
        }
    };
    let run_scan=Rc::new(run_scan); let rs=run_scan.clone(); scan.connect_clicked(move |_|rs());
    // Start a background scan shortly after opening so numbers appear automatically.
    let rs2=run_scan.clone(); glib::timeout_add_local_once(Duration::from_millis(550), move || rs2());

    let scroll=gtk::ScrolledWindow::builder().child(&body).vexpand(true).build(); page.append(&scroll); page
}
