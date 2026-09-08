import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_state.dart';
import '../../app/app_strings.dart';
import '../../core/vpn_core_providers.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, required this.appState});

  final AppState appState;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool? _credentialsSaved;
  bool _checkingCredentials = false;

  AppState get appState => widget.appState;

  @override
  void initState() {
    super.initState();
    Future.microtask(_refreshCredentialStatus);
  }

  Future<void> _refreshCredentialStatus() async {
    if (_checkingCredentials) return;
    setState(() => _checkingCredentials = true);
    try {
      final saved = await ref.read(vpnCoreProvider).credentialsSaved();
      if (mounted) setState(() => _credentialsSaved = saved);
    } catch (_) {
      if (mounted) setState(() => _credentialsSaved = false);
    } finally {
      if (mounted) setState(() => _checkingCredentials = false);
    }
  }

  Future<void> _showCredentialsDialog() async {
    final username = TextEditingController();
    final password = TextEditingController();
    var obscure = true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('VPN service credentials'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Use the provider manual/service credentials. The password is sent directly to the privileged helper and is not stored in Flutter preferences.'),
                const SizedBox(height: 16),
                TextField(
                  controller: username,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Service username', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: password,
                  obscureText: obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Service password',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      onPressed: () => setDialogState(() => obscure = !obscure),
                      icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final user = username.text.trim();
                final pass = password.text;
                if (user.isEmpty || pass.isEmpty) return;
                try {
                  await ref.read(vpnCoreProvider).saveCredentials(username: user, password: pass);
                  if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                } catch (error) {
                  if (dialogContext.mounted) {
                    ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(content: Text(error.toString())));
                  }
                }
              },
              child: const Text('Save securely'),
            ),
          ],
        ),
      ),
    );
    username.dispose();
    password.dispose();
    if (saved == true) {
      await _refreshCredentialStatus();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('VPN service credentials saved securely.')));
    }
  }

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
                    ListTile(
                      leading: Icon(_credentialsSaved == true ? Icons.verified_user_outlined : Icons.key_outlined),
                      title: const Text('VPN service credentials'),
                      subtitle: Text(_checkingCredentials
                          ? 'Checking secure storage…'
                          : _credentialsSaved == true
                              ? 'Saved in the privileged system store'
                              : 'Required before the first connection'),
                      trailing: FilledButton.tonal(
                        onPressed: _showCredentialsDialog,
                        child: Text(_credentialsSaved == true ? 'Replace' : 'Add'),
                      ),
                    ),
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
                      onChanged: (value) async {
                        await ref.read(vpnCoreProvider).setKillSwitch(value);
                        await appState.setKillSwitch(value);
                      },
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
                      onChanged: (value) async {
                        await ref.read(vpnCoreProvider).setDnsProtection(value);
                        await appState.setDnsProtection(value);
                      },
                    ),
                    SwitchListTile(
                      title: Text(strings.ipv6LeakProtection),
                      value: appState.ipv6Protection,
                      onChanged: (value) async {
                        await ref.read(vpnCoreProvider).setIpv6Protection(value);
                        await appState.setIpv6Protection(value);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Section(
                  title: strings.appearance,
                  children: [
                    RadioListTile<ThemeMode>(title: Text(strings.system), value: ThemeMode.system, groupValue: appState.themeMode, onChanged: _setTheme),
                    RadioListTile<ThemeMode>(title: Text(strings.light), value: ThemeMode.light, groupValue: appState.themeMode, onChanged: _setTheme),
                    RadioListTile<ThemeMode>(title: Text(strings.dark), value: ThemeMode.dark, groupValue: appState.themeMode, onChanged: _setTheme),
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
