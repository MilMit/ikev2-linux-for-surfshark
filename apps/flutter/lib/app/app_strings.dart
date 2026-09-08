class AppStrings {
  const AppStrings(this.localeCode);

  final String localeCode;

  bool get isFa => localeCode == 'fa';

  String get connect => isFa ? 'اتصال' : 'Connect';
  String get locations => isFa ? 'موقعیت‌ها' : 'Locations';
  String get statistics => isFa ? 'آمار' : 'Statistics';
  String get splitTunnel => isFa ? 'تفکیک مسیر' : 'Split Tunnel';
  String get diagnostics => isFa ? 'عیب‌یابی' : 'Diagnostics';
  String get settings => isFa ? 'تنظیمات' : 'Settings';

  String get connection => isFa ? 'اتصال' : 'Connection';
  String get autoConnect => isFa ? 'اتصال خودکار' : 'Auto-connect';
  String get autoConnectSubtitle => isFa
      ? 'در شبکه‌های پشتیبانی‌شده به‌صورت خودکار متصل شود'
      : 'Connect automatically on supported networks';
  String get killSwitch => isFa ? 'قطع اضطراری' : 'Kill switch';
  String get killSwitchSubtitle => isFa
      ? 'اگر اتصال VPN قطع شد، ترافیک اینترنت مسدود شود'
      : 'Block traffic if the VPN connection drops';
  String get protocol => isFa ? 'پروتکل' : 'Protocol';
  String get vpnProvider => isFa ? 'ارائه‌دهنده VPN' : 'VPN provider';
  String get providerSeparated => isFa
      ? 'لایه ارائه‌دهنده عمداً از رابط برنامه جدا نگه داشته شده است'
      : 'Provider layer is intentionally separated from the app UI';

  String get privacy => isFa ? 'حریم خصوصی' : 'Privacy';
  String get dnsLeakProtection => isFa ? 'محافظت در برابر نشت DNS' : 'DNS leak protection';
  String get ipv6LeakProtection => isFa ? 'محافظت در برابر نشت IPv6' : 'IPv6 leak protection';

  String get appearance => isFa ? 'ظاهر' : 'Appearance';
  String get system => isFa ? 'سیستم' : 'System';
  String get light => isFa ? 'روشن' : 'Light';
  String get dark => isFa ? 'تیره' : 'Dark';
}
