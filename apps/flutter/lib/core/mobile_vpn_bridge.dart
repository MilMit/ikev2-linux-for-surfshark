import 'dart:io';

import 'package:flutter/services.dart';

class MobileVpnStatus {
  const MobileVpnStatus({
    required this.state,
    this.protocol,
    this.message,
  });

  final String state;
  final String? protocol;
  final String? message;

  bool get isConnected => state == 'connected';
  bool get isTerminalError => state == 'error' || state.endsWith('_failed');
}

class MobileVpnBridge {
  MobileVpnBridge._();

  static const MethodChannel _android = MethodChannel('net.milmit.vpn/android');
  static const MethodChannel _ios = MethodChannel('net.milmit.vpn/ios');

  static MethodChannel get _channel {
    if (Platform.isAndroid) return _android;
    if (Platform.isIOS) return _ios;
    throw UnsupportedError('Mobile VPN bridge is only available on Android/iOS');
  }

  static Future<List<String>> supportedProtocols() async {
    if (!Platform.isAndroid && !Platform.isIOS) return const [];
    final values = await _channel.invokeListMethod<String>('supportedProtocols');
    return List<String>.unmodifiable(values ?? const <String>[]);
  }

  static Future<bool> prepare(String protocol) async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    return (await _channel.invokeMethod<bool>('prepare', <String, Object?>{
          'protocol': protocol.toLowerCase(),
        })) ??
        false;
  }

  static Future<void> connect({
    required String providerId,
    required String serverId,
    required String hostname,
    required String protocol,
  }) async {
    await _channel.invokeMethod<void>('connect', <String, Object?>{
      'providerId': providerId,
      'serverId': serverId,
      'hostname': hostname,
      'protocol': protocol.toLowerCase(),
    });
  }

  static Future<void> disconnect() async {
    await _channel.invokeMethod<void>('disconnect');
  }

  static Future<MobileVpnStatus> status() async {
    final value = await _channel.invokeMapMethod<String, Object?>('status') ?? const {};
    return MobileVpnStatus(
      state: (value['state'] as String?) ?? 'disconnected',
      protocol: value['protocol'] as String?,
      message: value['message'] as String?,
    );
  }

  static Future<bool> credentialsSaved() async {
    return (await _channel.invokeMethod<bool>('credentialsSaved')) ?? false;
  }

  static Future<void> saveCredentials({
    required String username,
    required String password,
  }) async {
    await _channel.invokeMethod<void>('saveCredentials', <String, Object?>{
      'username': username,
      'password': password,
    });
  }
}
