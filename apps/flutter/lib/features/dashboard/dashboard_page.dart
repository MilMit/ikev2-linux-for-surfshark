import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/vpn_core.dart';
import '../../core/vpn_core_providers.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionStateProvider);
    final servers = ref.watch(surfsharkServersProvider);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: connection.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => _ConnectionBody(
                state: VpnConnectionState(
                  status: VpnConnectionStatus.error,
                  errorMessage: error.toString(),
                ),
                servers: servers.valueOrNull ?? const [],
                onConnect: () => _connect(ref, servers.valueOrNull),
                onDisconnect: () => ref.read(vpnCoreProvider).disconnect(),
              ),
              data: (state) => _ConnectionBody(
                state: state,
                servers: servers.valueOrNull ?? const [],
                onConnect: () => _connect(ref, servers.valueOrNull),
                onDisconnect: () => ref.read(vpnCoreProvider).disconnect(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _connect(WidgetRef ref, List<VpnServer>? servers) async {
    final server = (servers == null || servers.isEmpty) ? null : servers.first;
    await ref.read(vpnCoreProvider).connect(
          providerId: 'surfshark',
          server: server,
          protocol: 'auto',
        );
  }
}

class _ConnectionBody extends StatelessWidget {
  const _ConnectionBody({
    required this.state,
    required this.servers,
    required this.onConnect,
    required this.onDisconnect,
  });

  final VpnConnectionState state;
  final List<VpnServer> servers;
  final Future<void> Function() onConnect;
  final Future<void> Function() onDisconnect;

  @override
  Widget build(BuildContext context) {
    final connected = state.status == VpnConnectionStatus.connected;
    final busy = state.status == VpnConnectionStatus.connecting ||
        state.status == VpnConnectionStatus.disconnecting;
    final server = state.server;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Connection', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              children: [
                Icon(
                  connected ? Icons.verified_user_rounded : Icons.shield_outlined,
                  size: 88,
                ),
                const SizedBox(height: 20),
                Text(
                  _statusText(state.status),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  server == null
                      ? 'Select a location or use fastest server'
                      : '${server.country} · ${server.city}',
                  textAlign: TextAlign.center,
                ),
                if (state.errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(state.errorMessage!, textAlign: TextAlign.center),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: busy ? null : () => connected ? onDisconnect() : onConnect(),
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(connected ? Icons.stop_circle_outlined : Icons.power_settings_new),
                  label: Text(connected ? 'Disconnect' : 'Quick connect'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(child: _StatusCard(title: 'Protocol', value: state.protocol ?? 'Auto')),
            const SizedBox(width: 12),
            const Expanded(child: _StatusCard(title: 'Provider', value: 'Surfshark')),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(child: _StatusCard(title: 'Kill switch', value: 'Ready')),
            const SizedBox(width: 12),
            Expanded(child: _StatusCard(title: 'Servers', value: '${servers.length} loaded')),
          ],
        ),
      ],
    );
  }

  static String _statusText(VpnConnectionStatus status) => switch (status) {
        VpnConnectionStatus.connected => 'Protected',
        VpnConnectionStatus.connecting => 'Connecting…',
        VpnConnectionStatus.disconnecting => 'Disconnecting…',
        VpnConnectionStatus.error => 'Connection error',
        VpnConnectionStatus.disconnected => 'Not connected',
      };
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.title, required this.value});

  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Text(value, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
