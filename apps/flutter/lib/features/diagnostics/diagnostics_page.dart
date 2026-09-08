import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/vpn_core_providers.dart';

class DiagnosticsPage extends ConsumerStatefulWidget {
  const DiagnosticsPage({super.key});

  @override
  ConsumerState<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends ConsumerState<DiagnosticsPage> {
  Map<String, Object?>? result;
  bool running = false;
  Object? error;

  Future<void> runChecks() async {
    setState(() {
      running = true;
      error = null;
    });
    try {
      final value = await ref.read(vpnCoreProvider).runDiagnostics();
      if (!mounted) return;
      setState(() => result = value);
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e);
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = result?.entries.toList() ?? const [];

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
                  child: entries.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: Text('Run checks to read diagnostics from the native Rust core.'),
                        )
                      : Column(
                          children: [
                            for (final entry in entries)
                              ListTile(
                                leading: const Icon(Icons.health_and_safety_outlined),
                                title: Text(entry.key),
                                subtitle: Text('${entry.value}'),
                              ),
                          ],
                        ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text('Diagnostics failed: $error'),
                ],
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: running ? null : runChecks,
                      icon: running
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                      label: const Text('Run checks'),
                    ),
                    OutlinedButton.icon(
                      onPressed: result == null ? null : () {},
                      icon: const Icon(Icons.description_outlined),
                      label: const Text('Export support bundle'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => setState(() {
                        result = null;
                        error = null;
                      }),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Clear results'),
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
}
