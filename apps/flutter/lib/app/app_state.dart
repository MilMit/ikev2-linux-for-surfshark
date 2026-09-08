import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppState extends ChangeNotifier {
  AppState._();

  static const _themeKey = 'theme_mode';
  static const _localeKey = 'locale';
  static const _autoConnectKey = 'auto_connect';
  static const _killSwitchKey = 'kill_switch';
  static const _dnsProtectionKey = 'dns_protection';
  static const _ipv6ProtectionKey = 'ipv6_protection';
  static const _protocolKey = 'protocol';
  static const _providerKey = 'provider';

  ThemeMode themeMode = ThemeMode.system;
  Locale locale = const Locale('en');
  bool autoConnect = true;
  bool killSwitch = true;
  bool dnsProtection = true;
  bool ipv6Protection = true;
  String protocol = 'Auto';
  String provider = 'Surfshark';

  static Future<AppState> load() async {
    final state = AppState._();
    final prefs = await SharedPreferences.getInstance();

    state.themeMode = switch (prefs.getString(_themeKey)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    state.locale = Locale(prefs.getString(_localeKey) ?? 'en');
    state.autoConnect = prefs.getBool(_autoConnectKey) ?? true;
    state.killSwitch = prefs.getBool(_killSwitchKey) ?? true;
    state.dnsProtection = prefs.getBool(_dnsProtectionKey) ?? true;
    state.ipv6Protection = prefs.getBool(_ipv6ProtectionKey) ?? true;
    state.protocol = prefs.getString(_protocolKey) ?? 'Auto';
    state.provider = prefs.getString(_providerKey) ?? 'Surfshark';

    return state;
  }

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, value.name);
  }

  Future<void> setLocale(Locale value) async {
    locale = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, value.languageCode);
  }

  Future<void> setAutoConnect(bool value) => _setBool(_autoConnectKey, value, () => autoConnect = value);
  Future<void> setKillSwitch(bool value) => _setBool(_killSwitchKey, value, () => killSwitch = value);
  Future<void> setDnsProtection(bool value) => _setBool(_dnsProtectionKey, value, () => dnsProtection = value);
  Future<void> setIpv6Protection(bool value) => _setBool(_ipv6ProtectionKey, value, () => ipv6Protection = value);

  Future<void> setProtocol(String value) async {
    protocol = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_protocolKey, value);
  }

  Future<void> setProvider(String value) async {
    provider = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerKey, value);
  }

  Future<void> _setBool(String key, bool value, VoidCallback update) async {
    update();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }
}
