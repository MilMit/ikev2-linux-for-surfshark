import 'package:flutter/material.dart';

import '../features/dashboard/dashboard_page.dart';
import '../features/locations/locations_page.dart';
import '../features/settings/settings_page.dart';

class VpnClientApp extends StatefulWidget {
  const VpnClientApp({super.key});

  @override
  State<VpnClientApp> createState() => _VpnClientAppState();
}

class _VpnClientAppState extends State<VpnClientApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VPN Client',
      themeMode: _themeMode,
      theme: ThemeData(useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark),
      home: AppShell(
        onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.onThemeModeChanged});

  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const DashboardPage(),
      const LocationsPage(),
      SettingsPage(onThemeModeChanged: widget.onThemeModeChanged),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        if (wide) {
          return Scaffold(
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
                  destinations: const [
                    NavigationRailDestination(icon: Icon(Icons.power_settings_new), label: Text('Connect')),
                    NavigationRailDestination(icon: Icon(Icons.public), label: Text('Locations')),
                    NavigationRailDestination(icon: Icon(Icons.settings), label: Text('Settings')),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: pages[_index]),
              ],
            ),
          );
        }

        return Scaffold(
          body: pages[_index],
          bottomNavigationBar: NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: (value) => setState(() => _index = value),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.power_settings_new), label: 'Connect'),
              NavigationDestination(icon: Icon(Icons.public), label: 'Locations'),
              NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
            ],
          ),
        );
      },
    );
  }
}
