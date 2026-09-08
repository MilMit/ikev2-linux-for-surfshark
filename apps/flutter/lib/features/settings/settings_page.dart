import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/app_strings.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings(appState.locale.languageCode);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(strings.settings, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 20),
                _Section(
                  title: strings.connection,
                  children: [
                    SwitchListTile(
                      title: Text(strings.autoConnect),
                      subtitle: Text(strings.autoConnectSubtitle),
                      value: appState.autoConnect,
                      onChanged: appState.setAutoConnect,
                    ),
                    SwitchListTile(
                      title: Text(strings.killSwitch),
                      subtitle: Text(strings.killSwitchSubtitle),
                      value: appState.killSwitch,
                      onChanged: appState.setKillSwitch,
                    ),
                    ListTile(
                      title: Text(strings.protocol),
                      trailing: DropdownButton<String>(
                        value: appState.protocol,
                        items: const ['Auto', 'WireGuard', 'IKEv2', 'OpenVPN']
                            .map((value) => DropdownMenuItem(value: value, child: Text(value)))
                            .toList(),
                        onChanged: (value) {
                          if (value != null) appState.setProtocol(value);
                        },
                      ),
                    ),
                    ListTile(
                      title: Text(strings.vpnProvider),
                      subtitle: Text(strings.providerSeparated),
                      trailing: DropdownButton<String>(
                        value: appState.provider,
                        items: const ['Surfshark']
                            .map((value) => DropdownMenuItem(value: value, child: Text(value)))
                            .toList(),
                        onChanged: (value) {
                          if (value != null) appState.setProvider(value);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: strings.privacy,
                  children: [
                    SwitchListTile(
                      title: Text(strings.dnsLeakProtection),
                      value: appState.dnsProtection,
                      onChanged: appState.setDnsProtection,
                    ),
                    SwitchListTile(
                      title: Text(strings.ipv6LeakProtection),
                      value: appState.ipv6Protection,
                      onChanged: appState.setIpv6Protection,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: strings.appearance,
                  children: [
                    RadioListTile<ThemeMode>(
                      title: Text(strings.system),
                      value: ThemeMode.system,
                      groupValue: appState.themeMode,
                      onChanged: _setTheme,
                    ),
                    RadioListTile<ThemeMode>(
                      title: Text(strings.light),
                      value: ThemeMode.light,
                      groupValue: appState.themeMode,
                      onChanged: _setTheme,
                    ),
                    RadioListTile<ThemeMode>(
                      title: Text(strings.dark),
                      value: ThemeMode.dark,
                      groupValue: appState.themeMode,
                      onChanged: _setTheme,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _setTheme(ThemeMode? value) {
    if (value != null) appState.setThemeMode(value);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ...children,
        ],
      ),
    );
  }
}
