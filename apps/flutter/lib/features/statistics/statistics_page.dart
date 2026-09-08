import 'package:flutter/material.dart';

class StatisticsPage extends StatelessWidget {
  const StatisticsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final items = [
      ('Today', '1.8 GB', Icons.today),
      ('This month', '24.6 GB', Icons.calendar_month),
      ('Sessions', '18', Icons.link),
      ('Protected time', '19h 42m', Icons.shield_outlined),
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: ListView(
              children: [
                Text('Statistics', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: items
                      .map((item) => SizedBox(
                            width: 220,
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(item.$3),
                                    const SizedBox(height: 16),
                                    Text(item.$2, style: Theme.of(context).textTheme.headlineSmall),
                                    const SizedBox(height: 4),
                                    Text(item.$1),
                                  ],
                                ),
                              ),
                            ),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 20),
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Traffic overview'),
                        SizedBox(height: 16),
                        LinearProgressIndicator(value: .62),
                        SizedBox(height: 8),
                        Text('UI placeholder for live RX/TX data from the shared core.'),
                      ],
                    ),
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
