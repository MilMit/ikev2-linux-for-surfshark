import 'package:flutter/material.dart';

class LocationsPage extends StatefulWidget {
  const LocationsPage({super.key});

  @override
  State<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends State<LocationsPage> {
  final controller = TextEditingController();

  static const locations = [
    ('Fastest location', 'Automatic', '—'),
    ('Germany', 'Frankfurt', '42 ms'),
    ('Netherlands', 'Amsterdam', '48 ms'),
    ('United Kingdom', 'London', '61 ms'),
    ('United States', 'New York', '88 ms'),
    ('Canada', 'Toronto', '96 ms'),
  ];

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = controller.text.trim().toLowerCase();
    final filtered = locations.where((item) {
      return item.$1.toLowerCase().contains(query) || item.$2.toLowerCase().contains(query);
    }).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Locations', style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 16),
                SearchBar(
                  controller: controller,
                  hintText: 'Search country or city',
                  leading: const Icon(Icons.search),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        return ListTile(
                          leading: CircleAvatar(child: Icon(index == 0 ? Icons.bolt : Icons.public)),
                          title: Text(item.$1),
                          subtitle: Text(item.$2),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(item.$3),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Favorite',
                                onPressed: () {},
                                icon: const Icon(Icons.star_border),
                              ),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () {},
                        );
                      },
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
