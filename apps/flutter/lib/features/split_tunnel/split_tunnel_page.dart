import 'package:flutter/material.dart';

import '../../core/linux_platform_controls.dart';

class SplitTunnelPage extends StatefulWidget {
  const SplitTunnelPage({super.key});

  @override
  State<SplitTunnelPage> createState() => _SplitTunnelPageState();
}

class _SplitTunnelPageState extends State<SplitTunnelPage> {
  final controls = LinuxPlatformControls();
  bool enabled = false;
  bool loading = true;
  List<Map<String, dynamic>> rules = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final state = await controls.splitStatus();
      if (!mounted) return;
      setState(() {
        enabled = state['enabled'] == true;
        rules = (state['rules'] as List? ?? const []).map((item) => Map<String, dynamic>.from(item as Map)).toList();
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _setEnabled(bool value) async {
    try {
      final state = await controls.setSplitEnabled(value);
      if (!mounted) return;
      setState(() {
        enabled = state['enabled'] == true;
        rules = (state['rules'] as List? ?? const []).map((item) => Map<String, dynamic>.from(item as Map)).toList();
      });
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _addRule() async {
    final controller = TextEditingController();
    var mode = 'bypass';
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add split tunnel rule'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Linux native split tunnel currently accepts CIDR targets, for example 10.0.0.0/8 or 203.0.113.10/32.'),
                const SizedBox(height: 12),
                TextField(controller: controller, decoration: const InputDecoration(labelText: 'CIDR target', border: OutlineInputBorder())),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: mode,
                  decoration: const InputDecoration(labelText: 'Routing mode', border: OutlineInputBorder()),
                  items: const [
                    DropdownMenuItem(value: 'bypass', child: Text('Bypass VPN')),
                    DropdownMenuItem(value: 'vpn', child: Text('Force VPN')),
                  ],
                  onChanged: (value) { if (value != null) setDialogState(() => mode = value); },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final target = controller.text.trim();
                if (target.isNotEmpty) Navigator.pop(dialogContext, (target, mode));
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (result == null) return;
    try {
      final state = await controls.addSplitRule(result.$1, result.$2);
      if (!mounted) return;
      setState(() => rules = (state['rules'] as List? ?? const []).map((item) => Map<String, dynamic>.from(item as Map)).toList());
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _removeRule(String target) async {
    try {
      final state = await controls.removeSplitRule(target);
      if (!mounted) return;
      setState(() => rules = (state['rules'] as List? ?? const []).map((item) => Map<String, dynamic>.from(item as Map)).toList());
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

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
                const Text('Native Linux CIDR bypass rules are applied through a privileged routing helper.'),
                const SizedBox(height: 20),
                Card(
                  child: SwitchListTile(
                    value: enabled,
                    onChanged: loading || !controls.supported ? null : _setEnabled,
                    title: const Text('Enable split tunneling'),
                    subtitle: Text(controls.supported ? 'Rules are persisted under the privileged Linux platform store.' : 'This native implementation is currently available on Linux.'),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: loading
                      ? const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
                      : rules.isEmpty
                          ? const Padding(padding: EdgeInsets.all(24), child: Text('No split tunnel rules yet.'))
                          : Column(
                              children: [
                                for (final rule in rules)
                                  ListTile(
                                    leading: const Icon(Icons.alt_route),
                                    title: Text('${rule['target']}'),
                                    subtitle: Text(rule['mode'] == 'bypass' ? 'Bypass VPN' : 'Force VPN'),
                                    trailing: IconButton(onPressed: () => _removeRule('${rule['target']}'), icon: const Icon(Icons.delete_outline)),
                                  ),
                              ],
                            ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(onPressed: enabled && controls.supported ? _addRule : null, icon: const Icon(Icons.add), label: const Text('Add CIDR rule')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
