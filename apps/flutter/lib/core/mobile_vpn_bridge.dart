import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

class MobileVpnStatus {
  const MobileVpnStatus({required this.state, this.message});

  final String state;
  final String? message;

  bool get isConnected => state == 'connected';
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

  static Future<bool> prepare() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    return (await _channel.invokeMethod<bool>('prepare')) ?? false;
  }

  static Future<void> connect({
    required String providerId,
    required String serverId,
    required String protocol,
  }) async {
    await _channel.invokeMethod<void>('connect', <String, Object?>{
      'providerId': providerId,
      'serverId': serverId,
      'protocol': protocol,
    });
  }

  static Future<void> disconnect() async {
    await _channel.invokeMethod<void>('disconnect');
  }

  static Future<MobileVpnStatus> status() async {
    final value = await _channel.invokeMapMethod<String, Object?>('status') ?? const {};
    return MobileVpnStatus(
      state: (value['state'] as String?) ?? 'disconnected',
      message: value['message'] as String?,
    );
  }
}
