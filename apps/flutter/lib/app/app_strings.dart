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
}
