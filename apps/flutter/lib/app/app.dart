import 'package:flutter/material.dart';

import '../features/dashboard/dashboard_page.dart';
import '../features/diagnostics/diagnostics_page.dart';
import '../features/locations/locations_page.dart';
import '../features/settings/settings_page.dart';
import '../features/split_tunnel/split_tunnel_page.dart';
import '../features/statistics/statistics_page.dart';
import 'app_strings.dart';

class VpnClientApp extends StatefulWidget {
  const VpnClientApp({super.key});

  @override
  State<VpnClientApp> createState() => _VpnClientAppState();
}

class _VpnClientAppState extends State<VpnClientApp> {
  ThemeMode _themeMode = ThemeMode.system;
  Locale _locale = const Locale('en');

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VPN Client',
      themeMode: _themeMode,
      locale: _locale,
      supportedLocales: const [Locale('en'), Locale('fa')],
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      builder: (context, child) {
        final rtl = _locale.languageCode == 'fa';
        return Directionality(
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: AppShell(
        locale: _locale,
        onLocaleChanged: (locale) => setState(() => _locale = locale),
        onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.locale,
    required this.onLocaleChanged,
    required this.onThemeModeChanged,
  });

  final Locale locale;
  final ValueChanged<Locale> onLocaleChanged;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(widget.locale.languageCode);
    final pages = [
      const DashboardPage(),
      const LocationsPage(),
      const StatisticsPage(),
      const SplitTunnelPage(),
      const DiagnosticsPage(),
      SettingsPage(onThemeModeChanged: widget.onThemeModeChanged),
    ];

    final destinations = [
      (Icons.power_settings_new, strings.connect),
      (Icons.public, strings.locations),
      (Icons.query_stats, strings.statistics),
      (Icons.alt_route, strings.splitTunnel),
      (Icons.health_and_safety_outlined, strings.diagnostics),
      (Icons.settings, strings.settings),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 980;
        if (wide) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('VPN Client'),
              actions: [
                _LanguageButton(locale: widget.locale, onChanged: widget.onLocaleChanged),
                const SizedBox(width: 8),
              ],
            ),
            body: Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (value) => setState(() => _index = value),
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Icon(Icons.shield_rounded, size: 36),
                  ),
                  destinations: [
                    for (final item in destinations)
                      NavigationRailDestination(icon: Icon(item.$1), label: Text(item.$2)),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: pages[_index]),
              ],
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('VPN Client'),
            actions: [_LanguageButton(locale: widget.locale, onChanged: widget.onLocaleChanged)],
          ),
          body: pages[_index],
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (value) => setState(() => _index = value),
            destinations: [
              for (final item in destinations)
                NavigationDestination(icon: Icon(item.$1), label: item.$2),
            ],
          ),
        );
      },
    );
  }
}

class _LanguageButton extends StatelessWidget {
  const _LanguageButton({required this.locale, required this.onChanged});

  final Locale locale;
  final ValueChanged<Locale> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Language',
      icon: const Icon(Icons.language),
      initialValue: locale.languageCode,
      onSelected: (value) => onChanged(Locale(value)),
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'en', child: Text('English')),
        PopupMenuItem(value: 'fa', child: Text('فارسی')),
      ],
    );
  }
}
