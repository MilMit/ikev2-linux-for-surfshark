import 'dart:async';

import 'mobile_vpn_bridge.dart';
import 'vpn_core.dart';

class MobileVpnCore implements VpnCore {
  MobileVpnCore(this._sharedCore);

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
        protocol: mapped == VpnConnectionStatus.disconnected ? null : _activeProtocol,
        errorMessage: mapped == VpnConnectionStatus.error ? (status.message ?? status.state) : null,
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

  @override
  Future<void> connect({
    required String providerId,
    VpnServer? server,
    required String protocol,
  }) async {
    if (server == null) {
      throw ArgumentError('A concrete mobile VPN server is required.');
    }
    if (protocol.toLowerCase() != 'wireguard') {
      throw UnsupportedError('Phase 5 mobile adapter currently supports WireGuard only.');
    }

    final prepared = await MobileVpnBridge.prepare();
    if (!prepared) {
      throw StateError('VPN permission was not granted.');
    }

    _activeServer = server;
    _activeProtocol = 'wireguard';
    _last = VpnConnectionState(
      status: VpnConnectionStatus.connecting,
      server: server,
      protocol: 'wireguard',
    );
    if (!_controller.isClosed) _controller.add(_last);

    await MobileVpnBridge.connect(
      providerId: providerId,
      serverId: server.id,
      protocol: 'wireguard',
    );
    await _pollStatus();
  }

  @override
  Future<void> disconnect() async {
    await MobileVpnBridge.disconnect();
    await _pollStatus();
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
    // Android/iOS VPN frameworks own the packet path. A mobile kill switch requires
    // platform-specific always-on/on-demand policy and is not emulated in Flutter.
    if (enabled) {
      throw UnsupportedError('Mobile kill switch policy is not configured yet.');
    }
  }

  @override
  Future<void> setDnsProtection(bool enabled) async {
    if (enabled) {
      throw UnsupportedError('Mobile DNS policy is supplied by the WireGuard profile.');
    }
  }

  @override
  Future<void> setIpv6Protection(bool enabled) async {
    if (enabled) {
      throw UnsupportedError('Mobile IPv6 policy is supplied by the WireGuard profile.');
    }
  }

  @override
  Future<bool> credentialsSaved() => _sharedCore.credentialsSaved();

  @override
  Future<void> saveCredentials({required String username, required String password}) =>
      _sharedCore.saveCredentials(username: username, password: password);

  @override
  Future<Map<String, Object?>> runDiagnostics() async {
    final shared = await _sharedCore.runDiagnostics();
    final native = await MobileVpnBridge.status();
    return {
      ...shared,
      'mobile_native_state': native.state,
      if (native.message != null) 'mobile_native_message': native.message!,
    };
  }
}
