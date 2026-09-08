import 'package:flutter/material.dart';

class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final checks = [
      ('Internet access', true, 'Reachable'),
      ('VPN engine', true, 'Ready'),
      ('DNS protection', true, 'Enabled'),
      ('IPv6 leak protection', true, 'Enabled'),
      ('Provider API', false, 'Not checked yet'),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              children: [
                Text('Diagnostics', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                const Text('Network Doctor and support tools'),
                const SizedBox(height: 20),
                Card(
                  child: Column(
                    children: [
                      for (final check in checks)
                        ListTile(
                          leading: Icon(check.$2 ? Icons.check_circle_outline : Icons.pending_outlined),
                          title: Text(check.$1),
                          subtitle: Text(check.$3),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(onPressed: () {}, icon: const Icon(Icons.play_arrow), label: const Text('Run checks')),
                    OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.description_outlined), label: const Text('Export support bundle')),
                    OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.delete_outline), label: const Text('Clear logs')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
