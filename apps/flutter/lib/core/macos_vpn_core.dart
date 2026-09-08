import 'dart:async';
import 'dart:io';

import 'package:milmit_vpn_macos/milmit_vpn_macos.dart';
import 'package:path_provider/path_provider.dart';

import 'vpn_core.dart';

class MacOsVpnCore implements VpnCore {
  MacOsVpnCore(this._delegate);

  final VpnCore _delegate;
  final MilMitVpnMacos _native = const MilMitVpnMacos();
  final StreamController<VpnConnectionState> _controller =
      StreamController<VpnConnectionState>.broadcast();

  Timer? _poller;
  bool _usingPacketTunnel = false;
  VpnServer? _activeServer;
  String? _activeProtocol;

  Future<VpnConnectionState> _packetTunnelState() async {
    final raw = await _native.status();
    final status = switch (raw) {
      'connecting' || 'reasserting' => VpnConnectionStatus.connecting,
      'connected' => VpnConnectionStatus.connected,
      'disconnecting' => VpnConnectionStatus.disconnecting,
      'invalid' => VpnConnectionStatus.error,
      _ => VpnConnectionStatus.disconnected,
    };
    return VpnConnectionState(
      status: status,
      server: _activeServer,
      protocol: _activeProtocol,
      errorMessage: raw == 'invalid' ? 'macOS PacketTunnel configuration is invalid.' : null,
    );
  }

  @override
  Stream<VpnConnectionState> watchConnection() {
    _poller ??= Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!_usingPacketTunnel) return;
      try {
        _controller.add(await _packetTunnelState());
      } catch (error) {
        _controller.add(VpnConnectionState(
          status: VpnConnectionStatus.error,
          server: _activeServer,
          protocol: _activeProtocol,
          errorMessage: error.toString(),
        ));
      }
    });

    final delegate = _delegate.watchConnection();
    return Stream.multi((output) {
      final nativeSub = _controller.stream.listen(output.add, onError: output.addError);
      final delegateSub = delegate.listen((state) {
        if (!_usingPacketTunnel) output.add(state);
      }, onError: output.addError);
      output.onCancel = () async {
        await nativeSub.cancel();
        await delegateSub.cancel();
      };
    });
  }

  @override
  Future<void> connect({required String providerId, VpnServer? server, required String protocol}) async {
    if (protocol.toLowerCase() != 'wireguard') {
      _usingPacketTunnel = false;
      return _delegate.connect(providerId: providerId, server: server, protocol: protocol);
    }

    final selected = server ?? (await _delegate.listServers(providerId: providerId)).firstOrNull;
    if (selected == null) throw StateError('No VPN server is available.');

    final support = await getApplicationSupportDirectory();
    final profile = File('${support.path}${Platform.pathSeparator}wireguard${Platform.pathSeparator}${selected.hostname}.conf');
    if (!await profile.exists()) {
      throw StateError('WireGuard profile is missing: ${profile.path}');
    }
    final wgQuick = await profile.readAsString();
    if (!wgQuick.contains('[Interface]') || !wgQuick.contains('[Peer]')) {
      throw StateError('WireGuard profile is invalid: ${profile.path}');
    }

    _usingPacketTunnel = true;
    _activeServer = selected;
    _activeProtocol = 'wireguard';
    _controller.add(VpnConnectionState(
      status: VpnConnectionStatus.connecting,
      server: selected,
      protocol: 'wireguard',
    ));

    try {
      await _native.start(
        serverAddress: selected.hostname,
        endpoint: selected.hostname,
        wireGuardQuickConfig: wgQuick,
      );
    } catch (_) {
      _usingPacketTunnel = false;
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_usingPacketTunnel) {
      await _native.stop();
      _usingPacketTunnel = false;
      _controller.add(VpnConnectionState(
        status: VpnConnectionStatus.disconnected,
        server: _activeServer,
        protocol: _activeProtocol,
      ));
      _activeServer = null;
      _activeProtocol = null;
      return;
    }
    await _delegate.disconnect();
  }

  @override
  Future<List<VpnServer>> listServers({required String providerId}) =>
      _delegate.listServers(providerId: providerId);

  @override
  Future<void> refreshServers({required String providerId}) =>
      _delegate.refreshServers(providerId: providerId);

  @override
  Future<int?> probeServer({required String providerId, required String serverId}) =>
      _delegate.probeServer(providerId: providerId, serverId: serverId);

  @override
  Future<void> setKillSwitch(bool enabled) => _delegate.setKillSwitch(enabled);

  @override
  Future<void> setDnsProtection(bool enabled) => _delegate.setDnsProtection(enabled);

  @override
  Future<void> setIpv6Protection(bool enabled) => _delegate.setIpv6Protection(enabled);

  @override
  Future<bool> credentialsSaved() => _delegate.credentialsSaved();

  @override
  Future<void> saveCredentials({required String username, required String password}) =>
      _delegate.saveCredentials(username: username, password: password);

  @override
  Future<Map<String, Object?>> runDiagnostics() async {
    final result = await _delegate.runDiagnostics();
    try {
      result['packet_tunnel_status'] = await _native.status();
      result['packet_tunnel_bridge'] = true;
    } catch (error) {
      result['packet_tunnel_bridge'] = false;
      result['packet_tunnel_error'] = error.toString();
    }
    return result;
  }
}

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
