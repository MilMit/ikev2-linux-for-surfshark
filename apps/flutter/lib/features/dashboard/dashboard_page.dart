import 'package:flutter/material.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  bool connected = false;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
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
                          connected ? 'Protected' : 'Not connected',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          connected ? 'Germany · Frankfurt' : 'Select a location or use fastest server',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        FilledButton.icon(
                          onPressed: () => setState(() => connected = !connected),
                          icon: Icon(connected ? Icons.stop_circle_outlined : Icons.power_settings_new),
                          label: Text(connected ? 'Disconnect' : 'Quick connect'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Row(
                  children: [
                    Expanded(child: _StatusCard(title: 'Protocol', value: 'Auto')),
                    SizedBox(width: 12),
                    Expanded(child: _StatusCard(title: 'Provider', value: 'Surfshark')),
                  ],
                ),
                const SizedBox(height: 12),
                const Row(
                  children: [
                    Expanded(child: _StatusCard(title: 'Kill switch', value: 'Ready')),
                    SizedBox(width: 12),
                    Expanded(child: _StatusCard(title: 'Public IP', value: '—')),
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
