import 'package:flutter/services.dart';

class MilMitVpnMacos {
  const MilMitVpnMacos();

  static const MethodChannel _channel = MethodChannel('net.milmit.vpn/macos');

  Future<void> start({
    required String serverAddress,
    required String endpoint,
    required String wireGuardQuickConfig,
    List<String> dnsServers = const [],
    List<String> includedRoutes = const [],
    List<String> excludedRoutes = const [],
  }) async {
    await _channel.invokeMethod<void>('start', <String, Object>{
      'serverAddress': serverAddress,
      'engine': 'wireguard',
      'endpoint': endpoint,
      'wireGuardQuickConfig': wireGuardQuickConfig,
      'dnsServers': dnsServers,
      'includedRoutes': includedRoutes,
      'excludedRoutes': excludedRoutes,
    });
  }

  Future<void> stop() => _channel.invokeMethod<void>('stop');

  Future<String> status() async =>
      (await _channel.invokeMethod<String>('status')) ?? 'invalid';
}
