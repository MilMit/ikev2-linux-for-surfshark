import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: VpnClientApp()));
}

class VpnClientApp extends StatelessWidget {
  const VpnClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VPN Client',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      home: const _FoundationPage(),
    );
  }
}

class _FoundationPage extends StatelessWidget {
  const _FoundationPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('VPN Client')),
      body: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined, size: 72),
            SizedBox(height: 16),
            Text('Flutter foundation ready'),
            SizedBox(height: 8),
            Text('Provider-independent UI migration has started.'),
          ],
        ),
      ),
    );
  }
}
