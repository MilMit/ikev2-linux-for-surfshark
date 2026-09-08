import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/vpn_core.dart';
import '../../core/vpn_core_providers.dart';

class LocationsPage extends ConsumerStatefulWidget {
  const LocationsPage({super.key});

  @override
  ConsumerState<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends ConsumerState<LocationsPage> {
  final controller = TextEditingController();
  final favorites = <String>{'de-fra'};
  final recent = <String>[];

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void toggleFavorite(VpnServer server) {
    setState(() {
      favorites.contains(server.id) ? favorites.remove(server.id) : favorites.add(server.id);
    });
  }

  void markRecent(VpnServer server) {
    setState(() {
      recent.remove(server.id);
      recent.insert(0, server.id);
      if (recent.length > 5) recent.removeLast();
    });
  }

  Future<void> connect(VpnServer server) async {
    markRecent(server);
    await ref.read(vpnCoreProvider).connect(
          providerId: server.providerId,
          server: server,
          protocol: 'auto',
        );
  }

  @override
  Widget build(BuildContext context) {
    final serversAsync = ref.watch(surfsharkServersProvider);
    final query = controller.text.trim().toLowerCase();

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
                  trailing: [
                    IconButton(
                      tooltip: 'Refresh servers',
                      onPressed: () async {
                        await ref.read(vpnCoreProvider).refreshServers(providerId: 'surfshark');
                        ref.invalidate(surfsharkServersProvider);
                      },
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: serversAsync.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (error, _) => Center(child: Text('Could not load servers: $error')),
                    data: (servers) {
                      final filtered = servers.where((server) {
                        return server.country.toLowerCase().contains(query) ||
                            server.city.toLowerCase().contains(query) ||
                            server.hostname.toLowerCase().contains(query);
                      }).toList();

                      final favoriteItems = servers.where((server) => favorites.contains(server.id)).toList();
                      final byId = {for (final server in servers) server.id: server};
                      final recentItems = recent.map((id) => byId[id]).whereType<VpnServer>().toList();

                      return Column(
                        children: [
                          if (favoriteItems.isNotEmpty || recentItems.isNotEmpty) ...[
                            SizedBox(
                              height: 52,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                children: [
                                  for (final server in favoriteItems)
                                    Padding(
                                      padding: const EdgeInsetsDirectional.only(end: 8),
                                      child: ActionChip(
                                        avatar: const Icon(Icons.star, size: 18),
                                        label: Text('${server.country} · ${server.city}'),
                                        onPressed: () => connect(server),
                                      ),
                                    ),
                                  for (final server in recentItems)
                                    if (!favorites.contains(server.id))
                                      Padding(
                                        padding: const EdgeInsetsDirectional.only(end: 8),
                                        child: ActionChip(
                                          avatar: const Icon(Icons.history, size: 18),
                                          label: Text('${server.country} · ${server.city}'),
                                          onPressed: () => connect(server),
                                        ),
                                      ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          Expanded(
                            child: Card(
                              clipBehavior: Clip.antiAlias,
                              child: ListView.separated(
                                itemCount: filtered.length + 1,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  if (index == 0) {
                                    return ListTile(
                                      leading: const CircleAvatar(child: Icon(Icons.bolt)),
                                      title: const Text('Fastest location'),
                                      subtitle: Text(servers.isEmpty ? 'No servers available' : 'Automatic'),
                                      trailing: const Icon(Icons.chevron_right),
                                      enabled: servers.isNotEmpty,
                                      onTap: servers.isEmpty ? null : () => connect(servers.first),
                                    );
                                  }

                                  final server = filtered[index - 1];
                                  final isFavorite = favorites.contains(server.id);
                                  return ListTile(
                                    leading: const CircleAvatar(child: Icon(Icons.public)),
                                    title: Text(server.country),
                                    subtitle: Text('${server.city} · ${server.hostname}'),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(server.latencyMs == null ? '—' : '${server.latencyMs} ms'),
                                        const SizedBox(width: 8),
                                        IconButton(
                                          tooltip: isFavorite ? 'Remove favorite' : 'Favorite',
                                          onPressed: () => toggleFavorite(server),
                                          icon: Icon(isFavorite ? Icons.star : Icons.star_border),
                                        ),
                                        const Icon(Icons.chevron_right),
                                      ],
                                    ),
                                    onTap: () => connect(server),
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    },
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
