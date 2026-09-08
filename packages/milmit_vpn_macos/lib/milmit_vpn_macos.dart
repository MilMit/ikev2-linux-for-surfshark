import 'package:flutter/services.dart';

class MilMitVpnMacosStatus {
  const MilMitVpnMacosStatus({required this.state, this.protocol, this.message});

  final String state;
  final String? protocol;
  final String? message;
}

class MilMitVpnMacos {
  const MilMitVpnMacos();

  static const MethodChannel _channel = MethodChannel('net.milmit.vpn/macos');

  Future<List<String>> supportedProtocols() async =>
      List<String>.unmodifiable(
        (await _channel.invokeListMethod<String>('supportedProtocols')) ?? const <String>[],
      );

  Future<void> start({
    required String serverAddress,
    required String protocol,
    String? endpoint,
    String? wireGuardQuickConfig,
    String? openVpnConfig,
    List<String> dnsServers = const [],
    List<String> includedRoutes = const [],
    List<String> excludedRoutes = const [],
  }) async {
    await _channel.invokeMethod<void>('start', <String, Object?>{
      'serverAddress': serverAddress,
      'protocol': protocol.toLowerCase(),
      'endpoint': endpoint,
      'wireGuardQuickConfig': wireGuardQuickConfig,
      'openVpnConfig': openVpnConfig,
      'dnsServers': dnsServers,
      'includedRoutes': includedRoutes,
      'excludedRoutes': excludedRoutes,
    });
  }

  Future<void> stop() => _channel.invokeMethod<void>('stop');

  Future<MilMitVpnMacosStatus> status() async {
    final map = await _channel.invokeMapMethod<String, Object?>('status') ?? const {};
    return MilMitVpnMacosStatus(
      state: map['state'] as String? ?? 'invalid',
      protocol: map['protocol'] as String?,
      message: map['message'] as String?,
    );
  }

  Future<bool> credentialsSaved() async =>
      (await _channel.invokeMethod<bool>('credentialsSaved')) ?? false;

  Future<void> saveCredentials({required String username, required String password}) =>
      _channel.invokeMethod<void>('saveCredentials', <String, Object>{
        'username': username,
        'password': password,
      });
}
