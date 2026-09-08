import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'macos_vpn_core.dart';
import 'rust_ffi_vpn_core.dart';
import 'vpn_core.dart';

final vpnCoreProvider = Provider<VpnCore>((ref) {
  try {
    final core = RustFfiVpnCore.open();
    return Platform.isMacOS ? MacOsVpnCore(core) : core;
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
