import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'vpn_core.dart';

typedef _GetStringNative = Pointer<Utf8> Function();
typedef _GetStringDart = Pointer<Utf8> Function();
typedef _ConnectNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _ConnectDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class RustFfiVpnCore implements VpnCore {
  RustFfiVpnCore._(this._library)
      : _version = _library.lookupFunction<_GetStringNative, _GetStringDart>('milmit_vpn_version'),
        _getState = _library.lookupFunction<_GetStringNative, _GetStringDart>('milmit_vpn_get_state'),
        _listServers = _library.lookupFunction<_GetStringNative, _GetStringDart>('milmit_vpn_list_servers'),
        _connect = _library.lookupFunction<_ConnectNative, _ConnectDart>('milmit_vpn_connect'),
        _disconnect = _library.lookupFunction<_GetStringNative, _GetStringDart>('milmit_vpn_disconnect'),
        _free = _library.lookupFunction<_FreeNative, _FreeDart>('milmit_vpn_string_free');

  factory RustFfiVpnCore.open() => RustFfiVpnCore._(_openLibrary());

  final DynamicLibrary _library;
  final _GetStringDart _version;
  final _GetStringDart _getState;
  final _GetStringDart _listServers;
  final _ConnectDart _connect;
  final _GetStringDart _disconnect;
  final _FreeDart _free;

  final _controller = StreamController<VpnConnectionState>.broadcast();
  Timer? _poller;

  static DynamicLibrary _openLibrary() {
    if (Platform.isWindows) return DynamicLibrary.open('milmit_vpn_flutter_ffi.dll');
    if (Platform.isMacOS || Platform.isIOS) return DynamicLibrary.open('libmilmit_vpn_flutter_ffi.dylib');
    if (Platform.isLinux || Platform.isAndroid) return DynamicLibrary.open('libmilmit_vpn_flutter_ffi.so');
    throw UnsupportedError('Unsupported platform for native VPN core');
  }

  String _readOwned(Pointer<Utf8> pointer) {
    final value = pointer.toDartString();
    _free(pointer);
    return value;
  }

  Map<String, dynamic> _jsonObject(Pointer<Utf8> pointer) =>
      jsonDecode(_readOwned(pointer)) as Map<String, dynamic>;

  Future<VpnConnectionState> _readState() async {
    final raw = _jsonObject(_getState());
    final status = switch (raw['status']) {
      'connecting' => VpnConnectionStatus.connecting,
      'connected' => VpnConnectionStatus.connected,
      'disconnecting' => VpnConnectionStatus.disconnecting,
      'error' => VpnConnectionStatus.error,
      _ => VpnConnectionStatus.disconnected,
    };

    VpnServer? server;
    final locationId = raw['location_id'] as String?;
    if (locationId != null) {
      final servers = await listServers(providerId: (raw['provider'] as String?) ?? 'surfshark');
      for (final item in servers) {
        if (item.id == locationId) {
          server = item;
          break;
        }
      }
    }

    return VpnConnectionState(
      status: status,
      server: server,
      protocol: raw['protocol'] as String?,
    );
  }

  @override
  Stream<VpnConnectionState> watchConnection() {
    _poller ??= Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        _controller.add(await _readState());
      } catch (error) {
        _controller.add(VpnConnectionState(
          status: VpnConnectionStatus.error,
          errorMessage: error.toString(),
        ));
      }
    });
    Future(() async => _controller.add(await _readState()));
    return _controller.stream;
  }

  @override
  Future<List<VpnServer>> listServers({required String providerId}) async {
    final raw = jsonDecode(_readOwned(_listServers())) as List<dynamic>;
    return raw
        .cast<Map<String, dynamic>>()
        .map((item) => VpnServer(
              id: item['id'] as String,
              providerId: providerId,
              country: item['country'] as String,
              city: item['city'] as String,
              hostname: item['hostname'] as String,
              latencyMs: item['latency_ms'] as int?,
            ))
        .toList(growable: false);
  }

  @override
  Future<void> refreshServers({required String providerId}) async {
    await listServers(providerId: providerId);
  }

  @override
  Future<void> connect({
    required String providerId,
    VpnServer? server,
    required String protocol,
  }) async {
    final selected = server ?? (await listServers(providerId: providerId)).first;
    final input = selected.id.toNativeUtf8();
    try {
      final result = _jsonObject(_connect(input));
      if (result['ok'] != true) {
        throw StateError((result['error'] as String?) ?? 'Native connect failed');
      }
      _controller.add(await _readState());
    } finally {
      malloc.free(input);
    }
  }

  @override
  Future<void> disconnect() async {
    final result = _jsonObject(_disconnect());
    if (result['ok'] != true) {
      throw StateError((result['error'] as String?) ?? 'Native disconnect failed');
    }
    _controller.add(await _readState());
  }

  @override
  Future<void> setKillSwitch(bool enabled) async {}

  @override
  Future<void> setDnsProtection(bool enabled) async {}

  @override
  Future<void> setIpv6Protection(bool enabled) async {}

  @override
  Future<Map<String, Object?>> runDiagnostics() async => {
        'core': 'rust-ffi',
        'version': _readOwned(_version()),
        'library': _library.toString(),
      };
}
