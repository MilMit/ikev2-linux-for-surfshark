import 'package:flutter/material.dart';

class SplitTunnelPage extends StatefulWidget {
  const SplitTunnelPage({super.key});

  @override
  State<SplitTunnelPage> createState() => _SplitTunnelPageState();
}

class _SplitTunnelPageState extends State<SplitTunnelPage> {
  bool enabled = false;
  final rules = <(String, String)>[
    ('bank.example', 'Bypass VPN'),
    ('10.0.0.0/8', 'Bypass VPN'),
    ('social.example', 'Force VPN'),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              children: [
                Text('Split Tunnel', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                const Text('Per-app, domain and CIDR routing policies'),
                const SizedBox(height: 20),
                Card(
                  child: SwitchListTile(
                    value: enabled,
                    onChanged: (value) => setState(() => enabled = value),
                    title: const Text('Enable split tunneling'),
                    subtitle: const Text('Routing is applied by the native platform adapter.'),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Column(
                    children: [
                      for (final rule in rules)
                        ListTile(
                          leading: const Icon(Icons.alt_route),
                          title: Text(rule.$1),
                          subtitle: Text(rule.$2),
                          trailing: IconButton(
                            onPressed: () => setState(() => rules.remove(rule)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: enabled ? () {} : null,
                    icon: const Icon(Icons.add),
                    label: const Text('Add rule'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
