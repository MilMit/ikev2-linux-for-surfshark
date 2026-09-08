import 'package:flutter/material.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.onThemeModeChanged});

  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ThemeMode themeMode = ThemeMode.system;
  bool autoConnect = true;
  bool killSwitch = true;
  bool dnsProtection = true;
  bool ipv6Protection = true;
  String protocol = 'Auto';
  String provider = 'Surfshark';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Settings', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 20),
                _Section(
                  title: 'Connection',
                  children: [
                    SwitchListTile(
                      title: const Text('Auto-connect'),
                      subtitle: const Text('Connect automatically on supported networks'),
                      value: autoConnect,
                      onChanged: (value) => setState(() => autoConnect = value),
                    ),
                    SwitchListTile(
                      title: const Text('Kill switch'),
                      subtitle: const Text('Block traffic if the VPN connection drops'),
                      value: killSwitch,
                      onChanged: (value) => setState(() => killSwitch = value),
                    ),
                    ListTile(
                      title: const Text('Protocol'),
                      trailing: DropdownButton<String>(
                        value: protocol,
                        items: const ['Auto', 'WireGuard', 'IKEv2', 'OpenVPN']
                            .map((value) => DropdownMenuItem(value: value, child: Text(value)))
                            .toList(),
                        onChanged: (value) => setState(() => protocol = value ?? protocol),
                      ),
                    ),
                    ListTile(
                      title: const Text('VPN provider'),
                      subtitle: const Text('Provider layer is intentionally separated from the app UI'),
                      trailing: DropdownButton<String>(
                        value: provider,
                        items: const ['Surfshark']
                            .map((value) => DropdownMenuItem(value: value, child: Text(value)))
                            .toList(),
                        onChanged: (value) => setState(() => provider = value ?? provider),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Privacy',
                  children: [
                    SwitchListTile(
                      title: const Text('DNS leak protection'),
                      value: dnsProtection,
                      onChanged: (value) => setState(() => dnsProtection = value),
                    ),
                    SwitchListTile(
                      title: const Text('IPv6 leak protection'),
                      value: ipv6Protection,
                      onChanged: (value) => setState(() => ipv6Protection = value),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: 'Appearance',
                  children: [
                    RadioListTile<ThemeMode>(
                      title: const Text('System'),
                      value: ThemeMode.system,
                      groupValue: themeMode,
                      onChanged: _setTheme,
                    ),
                    RadioListTile<ThemeMode>(
                      title: const Text('Light'),
                      value: ThemeMode.light,
                      groupValue: themeMode,
                      onChanged: _setTheme,
                    ),
                    RadioListTile<ThemeMode>(
                      title: const Text('Dark'),
                      value: ThemeMode.dark,
                      groupValue: themeMode,
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
    if (value == null) return;
    setState(() => themeMode = value);
    widget.onThemeModeChanged(value);
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
