import 'vpn_core.dart';

/// Enforces the same protocol names and Auto preference order on desktop.
///
/// Platform adapters remain responsible for the actual native/helper execution.
/// Auto retries the next engine when the selected adapter rejects an attempt
/// synchronously (missing engine/profile/service, provisioning error, etc.).
class DesktopProtocolParityVpnCore implements VpnCore {
  DesktopProtocolParityVpnCore(this._delegate);

  static const List<String> autoOrder = <String>['wireguard', 'ikev2', 'openvpn'];

  final VpnCore _delegate;

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

  @override
  Future<void> connect({
    required String providerId,
    VpnServer? server,
    required String protocol,
  }) async {
    final normalized = _normalize(protocol);
    if (normalized != 'auto') {
      return _delegate.connect(
        providerId: providerId,
        server: server,
        protocol: normalized,
      );
    }

    final errors = <String>[];
    for (final candidate in autoOrder) {
      try {
        await _delegate.connect(
          providerId: providerId,
          server: server,
          protocol: candidate,
        );
        return;
      } catch (error) {
        errors.add('$candidate: $error');
        try {
          await _delegate.disconnect();
        } catch (_) {
          // Failed setup may have nothing to tear down.
        }
      }
    }
    throw StateError('All desktop VPN protocols failed: ${errors.join(' | ')}');
  }

  @override
  Stream<VpnConnectionState> watchConnection() => _delegate.watchConnection();
  @override
  Future<List<VpnServer>> listServers({required String providerId}) => _delegate.listServers(providerId: providerId);
  @override
  Future<void> refreshServers({required String providerId}) => _delegate.refreshServers(providerId: providerId);
  @override
  Future<int?> probeServer({required String providerId, required String serverId}) => _delegate.probeServer(providerId: providerId, serverId: serverId);
  @override
  Future<void> disconnect() => _delegate.disconnect();
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
    final value = await _delegate.runDiagnostics();
    return <String, Object?>{
      ...value,
      'desktop_protocol_parity': true,
      'desktop_supported_protocols': const <String>['wireguard', 'ikev2', 'openvpn'],
      'desktop_auto_order': autoOrder,
    };
  }
}
