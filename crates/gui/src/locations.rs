#[derive(Clone, Copy, Debug)]
pub struct Location {
    pub id: &'static str,
    pub label: &'static str,
    pub country: &'static str,
    pub city: &'static str,
    pub host: &'static str,
}

pub const LOCATIONS: &[Location] = &[
    Location { id: "tr-ist", label: "🇹🇷 Türkiye · Istanbul", country: "Türkiye", city: "Istanbul", host: "tr-ist.prod.surfshark.com" },
    Location { id: "de-ber", label: "🇩🇪 Germany · Berlin", country: "Germany", city: "Berlin", host: "de-ber.prod.surfshark.com" },
    Location { id: "de-fra", label: "🇩🇪 Germany · Frankfurt", country: "Germany", city: "Frankfurt", host: "de-fra.prod.surfshark.com" },
    Location { id: "nl-ams", label: "🇳🇱 Netherlands · Amsterdam", country: "Netherlands", city: "Amsterdam", host: "nl-ams.prod.surfshark.com" },
    Location { id: "uk-lon", label: "🇬🇧 United Kingdom · London", country: "United Kingdom", city: "London", host: "uk-lon.prod.surfshark.com" },
    Location { id: "fr-par", label: "🇫🇷 France · Paris", country: "France", city: "Paris", host: "fr-par.prod.surfshark.com" },
    Location { id: "ch-zur", label: "🇨🇭 Switzerland · Zurich", country: "Switzerland", city: "Zurich", host: "ch-zur.prod.surfshark.com" },
    Location { id: "es-mad", label: "🇪🇸 Spain · Madrid", country: "Spain", city: "Madrid", host: "es-mad.prod.surfshark.com" },
    Location { id: "it-mil", label: "🇮🇹 Italy · Milan", country: "Italy", city: "Milan", host: "it-mil.prod.surfshark.com" },
    Location { id: "se-sto", label: "🇸🇪 Sweden · Stockholm", country: "Sweden", city: "Stockholm", host: "se-sto.prod.surfshark.com" },
    Location { id: "no-osl", label: "🇳🇴 Norway · Oslo", country: "Norway", city: "Oslo", host: "no-osl.prod.surfshark.com" },
    Location { id: "dk-cph", label: "🇩🇰 Denmark · Copenhagen", country: "Denmark", city: "Copenhagen", host: "dk-cph.prod.surfshark.com" },
    Location { id: "ie-dub", label: "🇮🇪 Ireland · Dublin", country: "Ireland", city: "Dublin", host: "ie-dub.prod.surfshark.com" },
    Location { id: "pl-waw", label: "🇵🇱 Poland · Warsaw", country: "Poland", city: "Warsaw", host: "pl-waw.prod.surfshark.com" },
    Location { id: "cz-prg", label: "🇨🇿 Czech Republic · Prague", country: "Czech Republic", city: "Prague", host: "cz-prg.prod.surfshark.com" },
    Location { id: "ro-buc", label: "🇷🇴 Romania · Bucharest", country: "Romania", city: "Bucharest", host: "ro-buc.prod.surfshark.com" },
    Location { id: "gr-ath", label: "🇬🇷 Greece · Athens", country: "Greece", city: "Athens", host: "gr-ath.prod.surfshark.com" },
    Location { id: "at-vie", label: "🇦🇹 Austria · Vienna", country: "Austria", city: "Vienna", host: "at-vie.prod.surfshark.com" },
    Location { id: "pt-lis", label: "🇵🇹 Portugal · Lisbon", country: "Portugal", city: "Lisbon", host: "pt-lis.prod.surfshark.com" },
    Location { id: "us-nyc", label: "🇺🇸 United States · New York", country: "United States", city: "New York", host: "us-nyc.prod.surfshark.com" },
    Location { id: "us-lax", label: "🇺🇸 United States · Los Angeles", country: "United States", city: "Los Angeles", host: "us-lax.prod.surfshark.com" },
    Location { id: "ca-tor", label: "🇨🇦 Canada · Toronto", country: "Canada", city: "Toronto", host: "ca-tor.prod.surfshark.com" },
    Location { id: "ca-van", label: "🇨🇦 Canada · Vancouver", country: "Canada", city: "Vancouver", host: "ca-van.prod.surfshark.com" },
    Location { id: "br-sao", label: "🇧🇷 Brazil · São Paulo", country: "Brazil", city: "São Paulo", host: "br-sao.prod.surfshark.com" },
    Location { id: "jp-tok", label: "🇯🇵 Japan · Tokyo", country: "Japan", city: "Tokyo", host: "jp-tok.prod.surfshark.com" },
    Location { id: "sg-sng", label: "🇸🇬 Singapore · Singapore", country: "Singapore", city: "Singapore", host: "sg-sng.prod.surfshark.com" },
    Location { id: "kr-seo", label: "🇰🇷 South Korea · Seoul", country: "South Korea", city: "Seoul", host: "kr-seo.prod.surfshark.com" },
    Location { id: "au-syd", label: "🇦🇺 Australia · Sydney", country: "Australia", city: "Sydney", host: "au-syd.prod.surfshark.com" },
    Location { id: "ae-dub", label: "🇦🇪 UAE · Dubai", country: "United Arab Emirates", city: "Dubai", host: "ae-dub.prod.surfshark.com" },
    Location { id: "za-jnb", label: "🇿🇦 South Africa · Johannesburg", country: "South Africa", city: "Johannesburg", host: "za-jnb.prod.surfshark.com" },
];

pub fn by_id(id: &str) -> Option<Location> {
    LOCATIONS.iter().copied().find(|item| item.id == id)
}

pub fn by_host(host: &str) -> Option<Location> {
    LOCATIONS.iter().copied().find(|item| item.host == host)
}
