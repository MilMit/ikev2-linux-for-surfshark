import 'dart:async';
import 'dart:io';

import 'package:milmit_vpn_macos/milmit_vpn_macos.dart';
import 'package:path_provider/path_provider.dart';

import 'vpn_core.dart';

class MacOsVpnCore implements VpnCore {
  MacOsVpnCore(this._delegate);

  static const List<String> autoOrder = <String>['wireguard', 'ikev2', 'openvpn'];

  final VpnCore _delegate;
  final MilMitVpnMacos _native = const MilMitVpnMacos();
  final StreamController<VpnConnectionState> _controller =
      StreamController<VpnConnectionState>.broadcast();

  Timer? _poller;
  VpnServer? _activeServer;
  String? _activeProtocol;

  Future<VpnConnectionState> _nativeState() async {
    final raw = await _native.status();
    final status = switch (raw.state) {
      'connecting' || 'reasserting' => VpnConnectionStatus.connecting,
      'connected' => VpnConnectionStatus.connected,
      'disconnecting' => VpnConnectionStatus.disconnecting,
      'invalid' || 'error' => VpnConnectionStatus.error,
      _ => VpnConnectionStatus.disconnected,
    };
    return VpnConnectionState(
      status: status,
      server: status == VpnConnectionStatus.disconnected ? null : _activeServer,
      protocol: status == VpnConnectionStatus.disconnected ? null : (raw.protocol ?? _activeProtocol),
      errorMessage: status == VpnConnectionStatus.error ? (raw.message ?? raw.state) : null,
    );
  }

  @override
  Stream<VpnConnectionState> watchConnection() {
    _poller ??= Timer.periodic(const Duration(seconds: 1), (_) async {
      try { _controller.add(await _nativeState()); }
      catch (error) {
        _controller.add(VpnConnectionState(
          status: VpnConnectionStatus.error,
          server: _activeServer,
          protocol: _activeProtocol,
          errorMessage: error.toString(),
        ));
      }
    });
    scheduleMicrotask(() async => _controller.add(await _nativeState()));
    return _controller.stream;
  }

  String _normalize(String value) {
    final p = value.trim().toLowerCase().replaceAll('-', '');
    return switch (p) {
      'wg' || 'wireguard' => 'wireguard',
      'ike' || 'ikev2' => 'ikev2',
      'ovpn' || 'openvpn' => 'openvpn',
      'auto' || '' => 'auto',
      _ => throw UnsupportedError('Unsupported VPN protocol: $value'),
    };
  }

  Future<File?> _profile(String directory, VpnServer server, String ext) async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}${Platform.pathSeparator}$directory');
    for (final name in <String>[server.id, server.hostname]) {
      final file = File('${root.path}${Platform.pathSeparator}$name.$ext');
      if (await file.exists() && await file.length() > 0) return file;
    }
    return null;
  }

  Future<void> _connectOne(VpnServer server, String protocol) async {
    String? wgQuick;
    String? ovpn;
    if (protocol == 'wireguard') {
      final file = await _profile('wireguard', server, 'conf');
      if (file == null) throw StateError('WireGuard profile is missing for ${server.id}.');
      wgQuick = await file.readAsString();
      if (!wgQuick.contains('[Interface]') || !wgQuick.contains('[Peer]')) {
        throw StateError('WireGuard profile is invalid.');
      }
    } else if (protocol == 'openvpn') {
      final file = await _profile('openvpn', server, 'ovpn');
      if (file == null) throw StateError('OpenVPN profile is missing for ${server.id}.');
      ovpn = await file.readAsString();
      if (!ovpn.contains('remote ')) throw StateError('OpenVPN profile is invalid.');
    }

    _activeServer = server;
    _activeProtocol = protocol;
    _controller.add(VpnConnectionState(
      status: VpnConnectionStatus.connecting,
      server: server,
      protocol: protocol,
    ));
    await _native.start(
      serverAddress: server.hostname,
      endpoint: server.hostname,
      protocol: protocol,
      wireGuardQuickConfig: wgQuick,
      openVpnConfig: ovpn,
    );

    final deadline = DateTime.now().add(const Duration(seconds: 25));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 750));
      final state = await _native.status();
      if (state.state == 'connected') return;
      if (state.state == 'invalid' || state.state == 'error') {
        throw StateError(state.message ?? state.state);
      }
    }
    throw TimeoutException('$protocol did not reach connected state in time.');
  }

  @override
  Future<void> connect({required String providerId, VpnServer? server, required String protocol}) async {
    final selected = server ?? (await _delegate.listServers(providerId: providerId)).firstOrNull;
    if (selected == null) throw StateError('No VPN server is available.');
    final requested = _normalize(protocol);
    final supported = (await _native.supportedProtocols()).toSet();
    final candidates = requested == 'auto' ? autoOrder : <String>[requested];
    final errors = <String>[];

    for (final candidate in candidates) {
      if (!supported.contains(candidate)) { errors.add('$candidate: unavailable'); continue; }
      try {
        await _connectOne(selected, candidate);
        return;
      } catch (error) {
        errors.add('$candidate: $error');
        try { await _native.stop(); } catch (_) {}
      }
    }
    _activeServer = null;
    _activeProtocol = null;
    throw StateError('All macOS VPN protocols failed: ${errors.join(' | ')}');
  }

  @override
  Future<void> disconnect() async {
    await _native.stop();
    _activeServer = null;
    _activeProtocol = null;
    _controller.add(const VpnConnectionState(status: VpnConnectionStatus.disconnected));
  }

  @override
  Future<List<VpnServer>> listServers({required String providerId}) => _delegate.listServers(providerId: providerId);
  @override
  Future<void> refreshServers({required String providerId}) => _delegate.refreshServers(providerId: providerId);
  @override
  Future<int?> probeServer({required String providerId, required String serverId}) => _delegate.probeServer(providerId: providerId, serverId: serverId);
  @override
  Future<void> setKillSwitch(bool enabled) => _delegate.setKillSwitch(enabled);
  @override
  Future<void> setDnsProtection(bool enabled) => _delegate.setDnsProtection(enabled);
  @override
  Future<void> setIpv6Protection(bool enabled) => _delegate.setIpv6Protection(enabled);
  @override
  Future<bool> credentialsSaved() => _native.credentialsSaved();
  @override
  Future<void> saveCredentials({required String username, required String password}) => _native.saveCredentials(username: username, password: password);

  @override
  Future<Map<String, Object?>> runDiagnostics() async {
    final result = await _delegate.runDiagnostics();
    try {
      final status = await _native.status();
      result['native_vpn_state'] = status.state;
      result['native_vpn_protocol'] = status.protocol;
      result['native_supported_protocols'] = await _native.supportedProtocols();
      result['native_auto_order'] = autoOrder;
    } catch (error) {
      result['native_bridge_error'] = error.toString();
    }
    return result;
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
