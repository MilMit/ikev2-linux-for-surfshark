import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rust_ffi_vpn_core.dart';
import 'vpn_core.dart';

final vpnCoreProvider = Provider<VpnCore>((ref) {
  try {
    return RustFfiVpnCore.open();
  } catch (_) {
    return const UnsupportedVpnCore();
  }
});

final connectionStateProvider = StreamProvider<VpnConnectionState>((ref) {
  return ref.watch(vpnCoreProvider).watchConnection();
});

final surfsharkServersProvider = FutureProvider<List<VpnServer>>((ref) {
  return ref.watch(vpnCoreProvider).listServers(providerId: 'surfshark');
});
