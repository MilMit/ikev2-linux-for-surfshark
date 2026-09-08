import 'dart:async';

import 'mobile_vpn_bridge.dart';
import 'vpn_core.dart';

class MobileVpnCore implements VpnCore {
  MobileVpnCore(this._sharedCore);

  static const List<String> autoOrder = <String>[
    'wireguard',
    'ikev2',
    'openvpn',
  ];

  final VpnCore _sharedCore;
  final StreamController<VpnConnectionState> _controller =
      StreamController<VpnConnectionState>.broadcast();

  Timer? _poller;
  VpnServer? _activeServer;
  String? _activeProtocol;
  VpnConnectionState _last = const VpnConnectionState(
    status: VpnConnectionStatus.disconnected,
  );

  @override
  Stream<VpnConnectionState> watchConnection() {
    _ensurePolling();
    scheduleMicrotask(() => _controller.add(_last));
    return _controller.stream;
  }

  void _ensurePolling() {
    _poller ??= Timer.periodic(const Duration(seconds: 1), (_) => _pollStatus());
    unawaited(_pollStatus());
  }

  Future<void> _pollStatus() async {
    try {
      final status = await MobileVpnBridge.status();
      final mapped = switch (status.state) {
        'connected' => VpnConnectionStatus.connected,
        'connecting' => VpnConnectionStatus.connecting,
        'disconnecting' => VpnConnectionStatus.disconnecting,
        'disconnected' => VpnConnectionStatus.disconnected,
        _ => VpnConnectionStatus.error,
      };
      final next = VpnConnectionState(
        status: mapped,
        server: mapped == VpnConnectionStatus.disconnected ? null : _activeServer,
        protocol: mapped == VpnConnectionStatus.disconnected
            ? null
            : (status.protocol ?? _activeProtocol),
        errorMessage: mapped == VpnConnectionStatus.error
            ? (status.message ?? status.state)
            : null,
      );
      _last = next;
      if (!_controller.isClosed) _controller.add(next);
    } catch (error) {
      final next = VpnConnectionState(
        status: VpnConnectionStatus.error,
        server: _activeServer,
        protocol: _activeProtocol,
        errorMessage: error.toString(),
      );
      _last = next;
      if (!_controller.isClosed) _controller.add(next);
    }
  }

  String _normalizeProtocol(String value) {
    final protocol = value.trim().toLowerCase().replaceAll('-', '');
    return switch (protocol) {
      'wg' || 'wireguard' => 'wireguard',
      'ike' || 'ikev2' => 'ikev2',
      'ovpn' || 'openvpn' => 'openvpn',
      'auto' || '' => 'auto',
      _ => throw UnsupportedError('Unsupported VPN protocol: $value'),
    };
  }

  Future<void> _connectOne({
    required String providerId,
    required VpnServer server,
    required String protocol,
  }) async {
    final prepared = await MobileVpnBridge.prepare(protocol);
    if (!prepared) {
      throw StateError('$protocol permission or platform capability was not granted.');
    }

    _activeServer = server;
    _activeProtocol = protocol;
    _last = VpnConnectionState(
      status: VpnConnectionStatus.connecting,
      server: server,
      protocol: protocol,
    );
    if (!_controller.isClosed) _controller.add(_last);

    await MobileVpnBridge.connect(
      providerId: providerId,
      serverId: server.id,
      hostname: server.hostname,
      protocol: protocol,
    );

    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 750));
      final native = await MobileVpnBridge.status();
      if (native.state == 'connected') {
        await _pollStatus();
        return;
      }
      if (native.state == 'error' ||
          native.state.endsWith('_failed') ||
          native.state == 'unsupported_protocol' ||
          native.state == 'profile_missing' ||
          native.state == 'credentials_missing') {
        throw StateError(native.message ?? native.state);
      }
    }
    throw TimeoutException('$protocol did not reach connected state in time.');
  }

  @override
  Future<void> connect({
    required String providerId,
    VpnServer? server,
    required String protocol,
  }) async {
    if (server == null) {
      throw ArgumentError('A concrete mobile VPN server is required.');
    }

    final requested = _normalizeProtocol(protocol);
    final supported = (await MobileVpnBridge.supportedProtocols()).toSet();
    final candidates = requested == 'auto' ? autoOrder : <String>[requested];
    final errors = <String>[];

    for (final candidate in candidates) {
      if (!supported.contains(candidate)) {
        errors.add('$candidate: unavailable');
        continue;
      }
      try {
        await _connectOne(
          providerId: providerId,
          server: server,
          protocol: candidate,
        );
        return;
      } catch (error) {
        errors.add('$candidate: $error');
        try {
          await MobileVpnBridge.disconnect();
        } catch (_) {
          // Continue fallback even if teardown of a failed attempt reports an error.
        }
      }
    }

    _activeProtocol = null;
    _activeServer = null;
    throw StateError('All mobile VPN protocols failed: ${errors.join(' | ')}');
  }

  @override
  Future<void> disconnect() async {
    await MobileVpnBridge.disconnect();
    await _pollStatus();
    _activeServer = null;
    _activeProtocol = null;
  }

  @override
  Future<List<VpnServer>> listServers({required String providerId}) =>
      _sharedCore.listServers(providerId: providerId);

  @override
  Future<void> refreshServers({required String providerId}) =>
      _sharedCore.refreshServers(providerId: providerId);

  @override
  Future<int?> probeServer({required String providerId, required String serverId}) =>
      _sharedCore.probeServer(providerId: providerId, serverId: serverId);

  @override
  Future<void> setKillSwitch(bool enabled) async {
    if (enabled) {
      throw UnsupportedError(
        'Mobile kill switch requires platform always-on/on-demand policy and is configured separately.',
      );
    }
  }

  @override
  Future<void> setDnsProtection(bool enabled) async {
    if (enabled) {
      throw UnsupportedError('Mobile DNS policy is supplied by the active VPN profile.');
    }
  }

  @override
  Future<void> setIpv6Protection(bool enabled) async {
    if (enabled) {
      throw UnsupportedError('Mobile IPv6 policy is supplied by the active VPN profile.');
    }
  }

  @override
  Future<bool> credentialsSaved() => MobileVpnBridge.credentialsSaved();

  @override
  Future<void> saveCredentials({required String username, required String password}) =>
      MobileVpnBridge.saveCredentials(username: username, password: password);

  @override
  Future<Map<String, Object?>> runDiagnostics() async {
    final shared = await _sharedCore.runDiagnostics();
    final native = await MobileVpnBridge.status();
    return {
      ...shared,
      'mobile_native_state': native.state,
      'mobile_active_protocol': native.protocol ?? _activeProtocol,
      'mobile_supported_protocols': await MobileVpnBridge.supportedProtocols(),
      'mobile_auto_order': autoOrder,
      if (native.message != null) 'mobile_native_message': native.message!,
    };
  }
}
