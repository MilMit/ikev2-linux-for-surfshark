import 'package:flutter/material.dart';

class LocationsPage extends StatefulWidget {
  const LocationsPage({super.key});

  @override
  State<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends State<LocationsPage> {
  final controller = TextEditingController();
  final favorites = <String>{'Germany|Frankfurt'};
  final recent = <String>[];

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

  String keyFor((String, String, String) item) => '${item.$1}|${item.$2}';

  void toggleFavorite((String, String, String) item) {
    final key = keyFor(item);
    setState(() {
      favorites.contains(key) ? favorites.remove(key) : favorites.add(key);
    });
  }

  void markRecent((String, String, String) item) {
    final key = keyFor(item);
    setState(() {
      recent.remove(key);
      recent.insert(0, key);
      if (recent.length > 5) recent.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    final query = controller.text.trim().toLowerCase();
    final filtered = locations.where((item) {
      return item.$1.toLowerCase().contains(query) || item.$2.toLowerCase().contains(query);
    }).toList();

    final favoriteItems = locations.where((item) => favorites.contains(keyFor(item))).toList();
    final recentItems = recent
        .map((key) => locations.firstWhere((item) => keyFor(item) == key))
        .toList();

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
                if (favoriteItems.isNotEmpty || recentItems.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 76,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final item in favoriteItems)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(end: 8),
                            child: ActionChip(
                              avatar: const Icon(Icons.star, size: 18),
                              label: Text('${item.$1} · ${item.$2}'),
                              onPressed: () => markRecent(item),
                            ),
                          ),
                        for (final item in recentItems)
                          if (!favorites.contains(keyFor(item)))
                            Padding(
                              padding: const EdgeInsetsDirectional.only(end: 8),
                              child: ActionChip(
                                avatar: const Icon(Icons.history, size: 18),
                                label: Text('${item.$1} · ${item.$2}'),
                                onPressed: () => markRecent(item),
                              ),
                            ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Expanded(
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    child: ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = filtered[index];
                        final isFavorite = favorites.contains(keyFor(item));
                        return ListTile(
                          leading: CircleAvatar(child: Icon(item.$1 == 'Fastest location' ? Icons.bolt : Icons.public)),
                          title: Text(item.$1),
                          subtitle: Text(item.$2),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(item.$3),
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: isFavorite ? 'Remove favorite' : 'Favorite',
                                onPressed: () => toggleFavorite(item),
                                icon: Icon(isFavorite ? Icons.star : Icons.star_border),
                              ),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () => markRecent(item),
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
