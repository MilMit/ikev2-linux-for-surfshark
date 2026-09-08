enum VpnConnectionStatus { disconnected, connecting, connected, disconnecting, error }

class VpnServer {
  const VpnServer({
    required this.id,
    required this.providerId,
    required this.country,
    required this.city,
    required this.hostname,
    this.latencyMs,
  });

  final String id;
  final String providerId;
  final String country;
  final String city;
  final String hostname;
  final int? latencyMs;
}

class VpnConnectionState {
  const VpnConnectionState({
    required this.status,
    this.server,
    this.protocol,
    this.errorMessage,
  });

  final VpnConnectionStatus status;
  final VpnServer? server;
  final String? protocol;
  final String? errorMessage;
}

abstract interface class VpnCore {
  Stream<VpnConnectionState> watchConnection();
  Future<List<VpnServer>> listServers({required String providerId});
  Future<void> refreshServers({required String providerId});
  Future<int?> probeServer({required String providerId, required String serverId});
  Future<void> connect({
    required String providerId,
    VpnServer? server,
    required String protocol,
  });
  Future<void> disconnect();
  Future<void> setKillSwitch(bool enabled);
  Future<void> setDnsProtection(bool enabled);
  Future<void> setIpv6Protection(bool enabled);
  Future<bool> credentialsSaved();
  Future<void> saveCredentials({required String username, required String password});
  Future<Map<String, Object?>> runDiagnostics();
}

class UnsupportedVpnCore implements VpnCore {
  const UnsupportedVpnCore();

  @override
  Stream<VpnConnectionState> watchConnection() => Stream.value(
        const VpnConnectionState(status: VpnConnectionStatus.disconnected),
      );

  @override
  Future<List<VpnServer>> listServers({required String providerId}) async => const [];

  @override
  Future<void> refreshServers({required String providerId}) async {}

  @override
  Future<int?> probeServer({required String providerId, required String serverId}) async => null;

  @override
  Future<void> connect({
    required String providerId,
    VpnServer? server,
    required String protocol,
  }) async {
    throw UnsupportedError('Native VPN core is not connected yet.');
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> setKillSwitch(bool enabled) async {}

  @override
  Future<void> setDnsProtection(bool enabled) async {}

  @override
  Future<void> setIpv6Protection(bool enabled) async {}

  @override
  Future<bool> credentialsSaved() async => false;

  @override
  Future<void> saveCredentials({required String username, required String password}) async {
    throw UnsupportedError('Secure credential storage is not available on this platform yet.');
  }

  @override
  Future<Map<String, Object?>> runDiagnostics() async => {
        'core': 'unavailable',
        'message': 'Flutter contract is ready for the Rust/native adapter.',
      };
}
