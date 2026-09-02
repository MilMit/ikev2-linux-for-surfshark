#[derive(Clone, Copy, Debug)]
pub struct Location {
    pub id: &'static str,
    pub label: &'static str,
    pub country: &'static str,
    pub city: &'static str,
    pub host: &'static str,
}

// Surfshark location catalog used by the Linux client.
// Hostnames are real *.prod.surfshark.com location endpoints observed in
// Surfshark manual/OpenVPN server catalogs. Surfshark's account-side IKEv2
// Locations tab remains the authoritative source if a hostname changes.
//
// Snapshot checked against Surfshark's public server-location catalog on 2026-09-02.
// It contains every advertised country and every separately selectable city.
// The UI performs latency/availability checks at runtime, so stale/unreachable
// endpoints can be identified without blocking the interface.
pub const LOCATIONS: &[Location] = &[
    Location { id: "al-tia", label: "🇦🇱 Albania · Tirana", country: "Albania", city: "Tirana", host: "al-tia.prod.surfshark.com" },
    Location { id: "dz-alg", label: "🇩🇿 Algeria · Algiers", country: "Algeria", city: "Algiers", host: "dz-alg.prod.surfshark.com" },
    Location { id: "ad-leu", label: "🇦🇩 Andorra · Andorra la Vella", country: "Andorra", city: "Andorra la Vella", host: "ad-leu.prod.surfshark.com" },
    Location { id: "ar-bua", label: "🇦🇷 Argentina · Buenos Aires", country: "Argentina", city: "Buenos Aires", host: "ar-bua.prod.surfshark.com" },
    Location { id: "am-evn", label: "🇦🇲 Armenia · Yerevan", country: "Armenia", city: "Yerevan", host: "am-evn.prod.surfshark.com" },
    Location { id: "au-syd", label: "🇦🇺 Australia · Sydney", country: "Australia", city: "Sydney", host: "au-syd.prod.surfshark.com" },
    Location { id: "at-vie", label: "🇦🇹 Austria · Vienna", country: "Austria", city: "Vienna", host: "at-vie.prod.surfshark.com" },
    Location { id: "az-bak", label: "🇦🇿 Azerbaijan · Baku", country: "Azerbaijan", city: "Baku", host: "az-bak.prod.surfshark.com" },
    Location { id: "bs-nas", label: "🇧🇸 Bahamas · Nassau", country: "Bahamas", city: "Nassau", host: "bs-nas.prod.surfshark.com" },
    Location { id: "bd-dac", label: "🇧🇩 Bangladesh · Dhaka", country: "Bangladesh", city: "Dhaka", host: "bd-dac.prod.surfshark.com" },
    Location { id: "be-bru", label: "🇧🇪 Belgium · Brussels", country: "Belgium", city: "Brussels", host: "be-bru.prod.surfshark.com" },
    Location { id: "bz-blp", label: "🇧🇿 Belize · Belmopan", country: "Belize", city: "Belmopan", host: "bz-blp.prod.surfshark.com" },
    Location { id: "bt-pbh", label: "🇧🇹 Bhutan · Paro", country: "Bhutan", city: "Paro", host: "bt-pbh.prod.surfshark.com" },
    Location { id: "bo-sre", label: "🇧🇴 Bolivia · Sucre", country: "Bolivia", city: "Sucre", host: "bo-sre.prod.surfshark.com" },
    Location { id: "ba-sjj", label: "🇧🇦 Bosnia & Herzegovina · Sarajevo", country: "Bosnia & Herzegovina", city: "Sarajevo", host: "ba-sjj.prod.surfshark.com" },
    Location { id: "br-sao", label: "🇧🇷 Brazil · São Paulo", country: "Brazil", city: "São Paulo", host: "br-sao.prod.surfshark.com" },
    Location { id: "bn-bwn", label: "🇧🇳 Brunei · Bandar Seri Begawan", country: "Brunei", city: "Bandar Seri Begawan", host: "bn-bwn.prod.surfshark.com" },
    Location { id: "bg-sof", label: "🇧🇬 Bulgaria · Sofia", country: "Bulgaria", city: "Sofia", host: "bg-sof.prod.surfshark.com" },
    Location { id: "kh-pnh", label: "🇰🇭 Cambodia · Phnom Penh", country: "Cambodia", city: "Phnom Penh", host: "kh-pnh.prod.surfshark.com" },
    Location { id: "ca-tor", label: "🇨🇦 Canada · Toronto", country: "Canada", city: "Toronto", host: "ca-tor.prod.surfshark.com" },
    Location { id: "cl-san", label: "🇨🇱 Chile · Santiago", country: "Chile", city: "Santiago", host: "cl-san.prod.surfshark.com" },
    Location { id: "co-bog", label: "🇨🇴 Colombia · Bogotá", country: "Colombia", city: "Bogotá", host: "co-bog.prod.surfshark.com" },
    Location { id: "cr-sjn", label: "🇨🇷 Costa Rica · San José", country: "Costa Rica", city: "San José", host: "cr-sjn.prod.surfshark.com" },
    Location { id: "hr-zag", label: "🇭🇷 Croatia · Zagreb", country: "Croatia", city: "Zagreb", host: "hr-zag.prod.surfshark.com" },
    Location { id: "cy-nic", label: "🇨🇾 Cyprus · Nicosia", country: "Cyprus", city: "Nicosia", host: "cy-nic.prod.surfshark.com" },
    Location { id: "cz-prg", label: "🇨🇿 Czech Republic · Prague", country: "Czech Republic", city: "Prague", host: "cz-prg.prod.surfshark.com" },
    Location { id: "dk-cph", label: "🇩🇰 Denmark · Copenhagen", country: "Denmark", city: "Copenhagen", host: "dk-cph.prod.surfshark.com" },
    Location { id: "ec-uio", label: "🇪🇨 Ecuador · Quito", country: "Ecuador", city: "Quito", host: "ec-uio.prod.surfshark.com" },
    Location { id: "eg-cai", label: "🇪🇬 Egypt · Cairo", country: "Egypt", city: "Cairo", host: "eg-cai.prod.surfshark.com" },
    Location { id: "ee-tll", label: "🇪🇪 Estonia · Tallinn", country: "Estonia", city: "Tallinn", host: "ee-tll.prod.surfshark.com" },
    Location { id: "fi-hel", label: "🇫🇮 Finland · Helsinki", country: "Finland", city: "Helsinki", host: "fi-hel.prod.surfshark.com" },
    Location { id: "fr-par", label: "🇫🇷 France · Paris", country: "France", city: "Paris", host: "fr-par.prod.surfshark.com" },
    Location { id: "ge-tbs", label: "🇬🇪 Georgia · Tbilisi", country: "Georgia", city: "Tbilisi", host: "ge-tbs.prod.surfshark.com" },
    Location { id: "de-ber", label: "🇩🇪 Germany · Berlin", country: "Germany", city: "Berlin", host: "de-ber.prod.surfshark.com" },
    Location { id: "gh-acc", label: "🇬🇭 Ghana · Accra", country: "Ghana", city: "Accra", host: "gh-acc.prod.surfshark.com" },
    Location { id: "gr-ath", label: "🇬🇷 Greece · Athens", country: "Greece", city: "Athens", host: "gr-ath.prod.surfshark.com" },
    Location { id: "gl-goh", label: "🇬🇱 Greenland · Nuuk", country: "Greenland", city: "Nuuk", host: "gl-goh.prod.surfshark.com" },
    Location { id: "hk-hkg", label: "🇭🇰 Hong Kong · Hong Kong", country: "Hong Kong", city: "Hong Kong", host: "hk-hkg.prod.surfshark.com" },
    Location { id: "hu-bud", label: "🇭🇺 Hungary · Budapest", country: "Hungary", city: "Budapest", host: "hu-bud.prod.surfshark.com" },
    Location { id: "is-rkv", label: "🇮🇸 Iceland · Reykjavík", country: "Iceland", city: "Reykjavík", host: "is-rkv.prod.surfshark.com" },
    Location { id: "in-mum", label: "🇮🇳 India · Mumbai", country: "India", city: "Mumbai", host: "in-mum.prod.surfshark.com" },
    Location { id: "id-jak", label: "🇮🇩 Indonesia · Jakarta", country: "Indonesia", city: "Jakarta", host: "id-jak.prod.surfshark.com" },
    Location { id: "ie-dub", label: "🇮🇪 Ireland · Dublin", country: "Ireland", city: "Dublin", host: "ie-dub.prod.surfshark.com" },
    Location { id: "im-iom", label: "🇮🇲 Isle of Man · Douglas", country: "Isle of Man", city: "Douglas", host: "im-iom.prod.surfshark.com" },
    Location { id: "il-tlv", label: "🇮🇱 Israel · Tel Aviv", country: "Israel", city: "Tel Aviv", host: "il-tlv.prod.surfshark.com" },
    Location { id: "it-mil", label: "🇮🇹 Italy · Milan", country: "Italy", city: "Milan", host: "it-mil.prod.surfshark.com" },
    Location { id: "jp-tok", label: "🇯🇵 Japan · Tokyo", country: "Japan", city: "Tokyo", host: "jp-tok.prod.surfshark.com" },
    Location { id: "kz-ura", label: "🇰🇿 Kazakhstan · Oral", country: "Kazakhstan", city: "Oral", host: "kz-ura.prod.surfshark.com" },
    Location { id: "la-vte", label: "🇱🇦 Laos · Vientiane", country: "Laos", city: "Vientiane", host: "la-vte.prod.surfshark.com" },
    Location { id: "lv-rig", label: "🇱🇻 Latvia · Riga", country: "Latvia", city: "Riga", host: "lv-rig.prod.surfshark.com" },
    Location { id: "li-qvu", label: "🇱🇮 Liechtenstein · Vaduz", country: "Liechtenstein", city: "Vaduz", host: "li-qvu.prod.surfshark.com" },
    Location { id: "lt-vno", label: "🇱🇹 Lithuania · Vilnius", country: "Lithuania", city: "Vilnius", host: "lt-vno.prod.surfshark.com" },
    Location { id: "lu-ste", label: "🇱🇺 Luxembourg · Luxembourg", country: "Luxembourg", city: "Luxembourg", host: "lu-ste.prod.surfshark.com" },
    Location { id: "mo-mfm", label: "🇲🇴 Macau SAR China · Macau", country: "Macau SAR China", city: "Macau", host: "mo-mfm.prod.surfshark.com" },
    Location { id: "my-kul", label: "🇲🇾 Malaysia · Kuala Lumpur", country: "Malaysia", city: "Kuala Lumpur", host: "my-kul.prod.surfshark.com" },
    Location { id: "mt-mla", label: "🇲🇹 Malta · Valletta", country: "Malta", city: "Valletta", host: "mt-mla.prod.surfshark.com" },
    Location { id: "ma-rab", label: "🇲🇦 Morocco · Rabat", country: "Morocco", city: "Rabat", host: "ma-rab.prod.surfshark.com" },
    Location { id: "mx-qro", label: "🇲🇽 Mexico · Querétaro", country: "Mexico", city: "Querétaro", host: "mx-qro.prod.surfshark.com" },
    Location { id: "md-chi", label: "🇲🇩 Moldova · Chișinău", country: "Moldova", city: "Chișinău", host: "md-chi.prod.surfshark.com" },
    Location { id: "mc-mcm", label: "🇲🇨 Monaco · Monaco", country: "Monaco", city: "Monaco", host: "mc-mcm.prod.surfshark.com" },
    Location { id: "mn-uln", label: "🇲🇳 Mongolia · Ulaanbaatar", country: "Mongolia", city: "Ulaanbaatar", host: "mn-uln.prod.surfshark.com" },
    Location { id: "me-tgd", label: "🇲🇪 Montenegro · Podgorica", country: "Montenegro", city: "Podgorica", host: "me-tgd.prod.surfshark.com" },
    Location { id: "mm-nyt", label: "🇲🇲 Myanmar · Naypyidaw", country: "Myanmar (Burma)", city: "Naypyidaw", host: "mm-nyt.prod.surfshark.com" },
    Location { id: "np-ktm", label: "🇳🇵 Nepal · Kathmandu", country: "Nepal", city: "Kathmandu", host: "np-ktm.prod.surfshark.com" },
    Location { id: "nl-ams", label: "🇳🇱 Netherlands · Amsterdam", country: "Netherlands", city: "Amsterdam", host: "nl-ams.prod.surfshark.com" },
    Location { id: "nz-akl", label: "🇳🇿 New Zealand · Auckland", country: "New Zealand", city: "Auckland", host: "nz-akl.prod.surfshark.com" },
    Location { id: "ng-lag", label: "🇳🇬 Nigeria · Lagos", country: "Nigeria", city: "Lagos", host: "ng-lag.prod.surfshark.com" },
    Location { id: "mk-skp", label: "🇲🇰 North Macedonia · Skopje", country: "North Macedonia", city: "Skopje", host: "mk-skp.prod.surfshark.com" },
    Location { id: "no-osl", label: "🇳🇴 Norway · Oslo", country: "Norway", city: "Oslo", host: "no-osl.prod.surfshark.com" },
    Location { id: "pk-khi", label: "🇵🇰 Pakistan · Karachi", country: "Pakistan", city: "Karachi", host: "pk-khi.prod.surfshark.com" },
    Location { id: "pa-pac", label: "🇵🇦 Panama · Panama City", country: "Panama", city: "Panama City", host: "pa-pac.prod.surfshark.com" },
    Location { id: "py-asu", label: "🇵🇾 Paraguay · Asunción", country: "Paraguay", city: "Asunción", host: "py-asu.prod.surfshark.com" },
    Location { id: "pe-lim", label: "🇵🇪 Peru · Lima", country: "Peru", city: "Lima", host: "pe-lim.prod.surfshark.com" },
    Location { id: "ph-mnl", label: "🇵🇭 Philippines · Manila", country: "Philippines", city: "Manila", host: "ph-mnl.prod.surfshark.com" },
    Location { id: "pl-waw", label: "🇵🇱 Poland · Warsaw", country: "Poland", city: "Warsaw", host: "pl-waw.prod.surfshark.com" },
    Location { id: "pt-lis", label: "🇵🇹 Portugal · Lisbon", country: "Portugal", city: "Lisbon", host: "pt-lis.prod.surfshark.com" },
    Location { id: "pr-sju", label: "🇵🇷 Puerto Rico · San Juan", country: "Puerto Rico", city: "San Juan", host: "pr-sju.prod.surfshark.com" },
    Location { id: "ro-buc", label: "🇷🇴 Romania · Bucharest", country: "Romania", city: "Bucharest", host: "ro-buc.prod.surfshark.com" },
    Location { id: "sa-ruh", label: "🇸🇦 Saudi Arabia · Riyadh", country: "Saudi Arabia", city: "Riyadh", host: "sa-ruh.prod.surfshark.com" },
    Location { id: "rs-beg", label: "🇷🇸 Serbia · Belgrade", country: "Serbia", city: "Belgrade", host: "rs-beg.prod.surfshark.com" },
    Location { id: "sg-sng", label: "🇸🇬 Singapore · Singapore", country: "Singapore", city: "Singapore", host: "sg-sng.prod.surfshark.com" },
    Location { id: "sk-bts", label: "🇸🇰 Slovakia · Bratislava", country: "Slovakia", city: "Bratislava", host: "sk-bts.prod.surfshark.com" },
    Location { id: "si-lju", label: "🇸🇮 Slovenia · Ljubljana", country: "Slovenia", city: "Ljubljana", host: "si-lju.prod.surfshark.com" },
    Location { id: "za-jnb", label: "🇿🇦 South Africa · Johannesburg", country: "South Africa", city: "Johannesburg", host: "za-jnb.prod.surfshark.com" },
    Location { id: "kr-seo", label: "🇰🇷 South Korea · Seoul", country: "South Korea", city: "Seoul", host: "kr-seo.prod.surfshark.com" },
    Location { id: "es-mad", label: "🇪🇸 Spain · Madrid", country: "Spain", city: "Madrid", host: "es-mad.prod.surfshark.com" },
    Location { id: "lk-cmb", label: "🇱🇰 Sri Lanka · Colombo", country: "Sri Lanka", city: "Colombo", host: "lk-cmb.prod.surfshark.com" },
    Location { id: "se-sto", label: "🇸🇪 Sweden · Stockholm", country: "Sweden", city: "Stockholm", host: "se-sto.prod.surfshark.com" },
    Location { id: "ch-zur", label: "🇨🇭 Switzerland · Zurich", country: "Switzerland", city: "Zurich", host: "ch-zur.prod.surfshark.com" },
    Location { id: "tw-tai", label: "🇹🇼 Taiwan · Taichung City", country: "Taiwan", city: "Taichung City", host: "tw-tai.prod.surfshark.com" },
    Location { id: "th-bkk", label: "🇹🇭 Thailand · Bangkok", country: "Thailand", city: "Bangkok", host: "th-bkk.prod.surfshark.com" },
    Location { id: "tr-ist", label: "🇹🇷 Turkey · Istanbul", country: "Turkey", city: "Istanbul", host: "tr-ist.prod.surfshark.com" },
    Location { id: "ua-iev", label: "🇺🇦 Ukraine · Kyiv", country: "Ukraine", city: "Kyiv", host: "ua-iev.prod.surfshark.com" },
    Location { id: "ae-dub", label: "🇦🇪 United Arab Emirates · Dubai", country: "United Arab Emirates", city: "Dubai", host: "ae-dub.prod.surfshark.com" },
    Location { id: "uk-lon", label: "🇬🇧 United Kingdom · London", country: "United Kingdom", city: "London", host: "uk-lon.prod.surfshark.com" },
    Location { id: "us-nyc", label: "🇺🇸 United States · New York", country: "United States", city: "New York", host: "us-nyc.prod.surfshark.com" },
    Location { id: "uy-mvd", label: "🇺🇾 Uruguay · Montevideo", country: "Uruguay", city: "Montevideo", host: "uy-mvd.prod.surfshark.com" },
    Location { id: "uz-tas", label: "🇺🇿 Uzbekistan · Tashkent", country: "Uzbekistan", city: "Tashkent", host: "uz-tas.prod.surfshark.com" },
    Location { id: "ve-car", label: "🇻🇪 Venezuela · Caracas", country: "Venezuela", city: "Caracas", host: "ve-car.prod.surfshark.com" },
    Location { id: "vn-hcm", label: "🇻🇳 Vietnam · Ho Chi Minh City", country: "Vietnam", city: "Ho Chi Minh City", host: "vn-hcm.prod.surfshark.com" },

    // Extra cities where we have confirmed location hostnames.
    Location { id: "de-fra", label: "🇩🇪 Germany · Frankfurt", country: "Germany", city: "Frankfurt", host: "de-fra.prod.surfshark.com" },
    Location { id: "ca-van", label: "🇨🇦 Canada · Vancouver", country: "Canada", city: "Vancouver", host: "ca-van.prod.surfshark.com" },
    Location { id: "ca-mon", label: "🇨🇦 Canada · Montreal", country: "Canada", city: "Montreal", host: "ca-mon.prod.surfshark.com" },
    Location { id: "us-lax", label: "🇺🇸 United States · Los Angeles", country: "United States", city: "Los Angeles", host: "us-lax.prod.surfshark.com" },
    Location { id: "us-sfo", label: "🇺🇸 United States · San Francisco", country: "United States", city: "San Francisco", host: "us-sfo.prod.surfshark.com" },
    Location { id: "us-sea", label: "🇺🇸 United States · Seattle", country: "United States", city: "Seattle", host: "us-sea.prod.surfshark.com" },
    Location { id: "us-mia", label: "🇺🇸 United States · Miami", country: "United States", city: "Miami", host: "us-mia.prod.surfshark.com" },
    Location { id: "us-chi", label: "🇺🇸 United States · Chicago", country: "United States", city: "Chicago", host: "us-chi.prod.surfshark.com" },
    Location { id: "fr-bod", label: "🇫🇷 France · Bordeaux", country: "France", city: "Bordeaux", host: "fr-bod.prod.surfshark.com" },
    Location { id: "fr-mrs", label: "🇫🇷 France · Marseille", country: "France", city: "Marseille", host: "fr-mrs.prod.surfshark.com" },
    Location { id: "it-rom", label: "🇮🇹 Italy · Rome", country: "Italy", city: "Rome", host: "it-rom.prod.surfshark.com" },
    Location { id: "pl-gdn", label: "🇵🇱 Poland · Gdańsk", country: "Poland", city: "Gdańsk", host: "pl-gdn.prod.surfshark.com" },
    Location { id: "pt-opo", label: "🇵🇹 Portugal · Porto", country: "Portugal", city: "Porto", host: "pt-opo.prod.surfshark.com" },
    Location { id: "es-bcn", label: "🇪🇸 Spain · Barcelona", country: "Spain", city: "Barcelona", host: "es-bcn.prod.surfshark.com" },
    Location { id: "es-vlc", label: "🇪🇸 Spain · Valencia", country: "Spain", city: "Valencia", host: "es-vlc.prod.surfshark.com" },
    Location { id: "uk-man", label: "🇬🇧 United Kingdom · Manchester", country: "United Kingdom", city: "Manchester", host: "uk-man.prod.surfshark.com" },
    Location { id: "uk-edi", label: "🇬🇧 United Kingdom · Edinburgh", country: "United Kingdom", city: "Edinburgh", host: "uk-edi.prod.surfshark.com" },
    Location { id: "uk-gla", label: "🇬🇧 United Kingdom · Glasgow", country: "United Kingdom", city: "Glasgow", host: "uk-gla.prod.surfshark.com" },
    Location { id: "au-mel", label: "🇦🇺 Australia · Melbourne", country: "Australia", city: "Melbourne", host: "au-mel.prod.surfshark.com" },
    Location { id: "au-bne", label: "🇦🇺 Australia · Brisbane", country: "Australia", city: "Brisbane", host: "au-bne.prod.surfshark.com" },
    Location { id: "au-per", label: "🇦🇺 Australia · Perth", country: "Australia", city: "Perth", host: "au-per.prod.surfshark.com" },
    Location { id: "au-adl", label: "🇦🇺 Australia · Adelaide", country: "Australia", city: "Adelaide", host: "au-adl.prod.surfshark.com" },
    Location { id: "in-del", label: "🇮🇳 India · Delhi", country: "India", city: "Delhi", host: "in-del.prod.surfshark.com" },
    Location { id: "be-anr", label: "🇧🇪 Belgium · Antwerp", country: "Belgium", city: "Antwerp", host: "be-anr.prod.surfshark.com" },
    Location { id: "us-bos", label: "🇺🇸 United States · Boston", country: "United States", city: "Boston", host: "us-bos.prod.surfshark.com" },
    Location { id: "us-buf", label: "🇺🇸 United States · Buffalo", country: "United States", city: "Buffalo", host: "us-buf.prod.surfshark.com" },
    Location { id: "us-ash", label: "🇺🇸 United States · Ashburn", country: "United States", city: "Ashburn", host: "us-ash.prod.surfshark.com" },
    Location { id: "us-dtw", label: "🇺🇸 United States · Detroit", country: "United States", city: "Detroit", host: "us-dtw.prod.surfshark.com" },
    Location { id: "us-clt", label: "🇺🇸 United States · Charlotte", country: "United States", city: "Charlotte", host: "us-clt.prod.surfshark.com" },
    Location { id: "us-ltm", label: "🇺🇸 United States · Latham", country: "United States", city: "Latham", host: "us-ltm.prod.surfshark.com" },
    Location { id: "us-bna", label: "🇺🇸 United States · Nashville", country: "United States", city: "Nashville", host: "us-bna.prod.surfshark.com" },
    Location { id: "us-oma", label: "🇺🇸 United States · Omaha", country: "United States", city: "Omaha", host: "us-oma.prod.surfshark.com" },
    Location { id: "us-atl", label: "🇺🇸 United States · Atlanta", country: "United States", city: "Atlanta", host: "us-atl.prod.surfshark.com" },
    Location { id: "us-kan", label: "🇺🇸 United States · Kansas City", country: "United States", city: "Kansas City", host: "us-kan.prod.surfshark.com" },
    Location { id: "us-den", label: "🇺🇸 United States · Denver", country: "United States", city: "Denver", host: "us-den.prod.surfshark.com" },
    Location { id: "us-bdn", label: "🇺🇸 United States · Bend", country: "United States", city: "Bend", host: "us-bdn.prod.surfshark.com" },
    Location { id: "us-slc", label: "🇺🇸 United States · Salt Lake City", country: "United States", city: "Salt Lake City", host: "us-slc.prod.surfshark.com" },
    Location { id: "us-dal", label: "🇺🇸 United States · Dallas", country: "United States", city: "Dallas", host: "us-dal.prod.surfshark.com" },
    Location { id: "us-hou", label: "🇺🇸 United States · Houston", country: "United States", city: "Houston", host: "us-hou.prod.surfshark.com" },
    Location { id: "us-las", label: "🇺🇸 United States · Las Vegas", country: "United States", city: "Las Vegas", host: "us-las.prod.surfshark.com" },
    Location { id: "us-sjc", label: "🇺🇸 United States · San Jose", country: "United States", city: "San Jose", host: "us-sjc.prod.surfshark.com" },
    Location { id: "us-phx", label: "🇺🇸 United States · Phoenix", country: "United States", city: "Phoenix", host: "us-phx.prod.surfshark.com" },
];

pub fn by_id(id: &str) -> Option<Location> {
    LOCATIONS.iter().copied().find(|item| item.id == id)
}

pub fn by_host(host: &str) -> Option<Location> {
    if host.is_empty() {
        return None;
    }
    LOCATIONS.iter().copied().find(|item| item.host == host)
}

#[cfg(test)]
mod tests {
    use super::LOCATIONS;
    use std::collections::HashSet;

    #[test]
    fn catalog_covers_current_surfshark_locations_without_duplicates() {
        let ids: HashSet<_> = LOCATIONS.iter().map(|item| item.id).collect();
        let hosts: HashSet<_> = LOCATIONS.iter().map(|item| item.host).collect();
        let countries: HashSet<_> = LOCATIONS.iter().map(|item| item.country).collect();
        assert_eq!(ids.len(), LOCATIONS.len(), "duplicate location id");
        assert_eq!(hosts.len(), LOCATIONS.len(), "duplicate location hostname");
        assert_eq!(countries.len(), 100, "Surfshark currently advertises 100 countries");
        for id in ["fr-mrs", "uk-edi", "us-ash", "us-bna", "us-oma", "us-sjc"] {
            assert!(ids.contains(id), "missing advertised location {id}");
        }
    }
}
