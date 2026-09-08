import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

import 'vpn_core.dart';

typedef _GetStringNative = Pointer<Utf8> Function();
typedef _GetStringDart = Pointer<Utf8> Function();
typedef _OneStringNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _OneStringDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _TwoStringNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _TwoStringDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _ThreeStringNative = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _ThreeStringDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _BoolNative = Pointer<Utf8> Function(Bool);
typedef _BoolDart = Pointer<Utf8> Function(bool);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class RustFfiVpnCore implements VpnCore {
  RustFfiVpnCore._(this._library)
      : _version = _library.lookupFunction<_GetStringNative, _GetStringDart>('milmit_vpn_version'),
        _init = _library.lookupFunction<_OneStringNative, _OneStringDart>('milmit_vpn_init'),
        _getState = _library.lookupFunction<_GetStringNative, _GetStringDart>('milmit_vpn_get_state'),
        _listServers = _library.lookupFunction<_OneStringNative, _OneStringDart>('milmit_vpn_list_servers'),
        _applyCatalog = _library.lookupFunction<_TwoStringNative, _TwoStringDart>('milmit_vpn_apply_catalog_update'),
        _connect = _library.lookupFunction<_ThreeStringNative, _ThreeStringDart>('milmit_vpn_connect'),
        _disconnect = _library.lookupFunction<_GetStringNative, _GetStringDart>('milmit_vpn_disconnect'),
        _setKillSwitch = _library.lookupFunction<_BoolNative, _BoolDart>('milmit_vpn_set_kill_switch'),
        _setDnsProtection = _library.lookupFunction<_BoolNative, _BoolDart>('milmit_vpn_set_dns_protection'),
        _setIpv6Protection = _library.lookupFunction<_BoolNative, _BoolDart>('milmit_vpn_set_ipv6_protection'),
        _diagnostics = _library.lookupFunction<_GetStringNative, _GetStringDart>('milmit_vpn_diagnostics'),
        _free = _library.lookupFunction<_FreeNative, _FreeDart>('milmit_vpn_string_free');

  factory RustFfiVpnCore.open() => RustFfiVpnCore._(_openLibrary());

  final DynamicLibrary _library;
  final _GetStringDart _version;
  final _OneStringDart _init;
  final _GetStringDart _getState;
  final _OneStringDart _listServers;
  final _TwoStringDart _applyCatalog;
  final _ThreeStringDart _connect;
  final _GetStringDart _disconnect;
  final _BoolDart _setKillSwitch;
  final _BoolDart _setDnsProtection;
  final _BoolDart _setIpv6Protection;
  final _GetStringDart _diagnostics;
  final _FreeDart _free;

  final _controller = StreamController<VpnConnectionState>.broadcast();
  Timer? _poller;
  Future<void>? _initialization;

  static DynamicLibrary _openLibrary() {
    if (Platform.isWindows) return DynamicLibrary.open('milmit_vpn_flutter_ffi.dll');
    if (Platform.isMacOS || Platform.isIOS) return DynamicLibrary.open('libmilmit_vpn_flutter_ffi.dylib');
    if (Platform.isLinux || Platform.isAndroid) return DynamicLibrary.open('libmilmit_vpn_flutter_ffi.so');
    throw UnsupportedError('Unsupported platform for native VPN core');
  }

  Future<void> _ensureInitialized() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    final support = await getApplicationSupportDirectory();
    final cache = Directory('${support.path}${Platform.pathSeparator}vpn-catalogs');
    await cache.create(recursive: true);
    final input = cache.path.toNativeUtf8();
    try {
      final result = _jsonObject(_init(input));
      if (result['ok'] != true) {
        throw StateError((result['error'] as String?) ?? 'Native catalog initialization failed');
      }
    } finally {
      malloc.free(input);
    }
  }

  String _readOwned(Pointer<Utf8> pointer) {
    final value = pointer.toDartString();
    _free(pointer);
    return value;
  }

  Map<String, dynamic> _jsonObject(Pointer<Utf8> pointer) => jsonDecode(_readOwned(pointer)) as Map<String, dynamic>;
  Pointer<Utf8> _utf8(String value) => value.toNativeUtf8();

  String? _catalogUrl(String providerId) {
    switch (providerId.toLowerCase()) {
      case 'surfshark':
        const value = String.fromEnvironment('VPN_CATALOG_SURFSHARK_URL');
        return value.isEmpty ? null : value;
      default:
        return null;
    }
  }

  Future<String> _downloadCatalog(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(const Duration(seconds: 12));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Catalog update HTTP ${response.statusCode}', uri: uri);
      }
      return response.transform(utf8.decoder).join().timeout(const Duration(seconds: 12));
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _applyCatalogJson(String providerId, String catalogJson) async {
    await _ensureInitialized();
    final provider = _utf8(providerId);
    final jsonPtr = _utf8(catalogJson);
    try {
      return _jsonObject(_applyCatalog(provider, jsonPtr));
    } finally {
      malloc.free(provider);
      malloc.free(jsonPtr);
    }
  }

  Future<VpnConnectionState> _readState() async {
    await _ensureInitialized();
    final raw = _jsonObject(_getState());
    final status = switch (raw['status']) {
      'connecting' => VpnConnectionStatus.connecting,
      'connected' => VpnConnectionStatus.connected,
      'disconnecting' => VpnConnectionStatus.disconnecting,
      'error' => VpnConnectionStatus.error,
      _ => VpnConnectionStatus.disconnected,
    };
    VpnServer? server;
    final providerId = (raw['provider'] as String?) ?? 'surfshark';
    final locationId = raw['location_id'] as String?;
    if (locationId != null) {
      for (final item in await listServers(providerId: providerId)) {
        if (item.id == locationId) {
          server = item;
          break;
        }
      }
    }
    return VpnConnectionState(status: status, server: server, protocol: raw['protocol'] as String?);
  }

  @override
  Stream<VpnConnectionState> watchConnection() {
    _poller ??= Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        _controller.add(await _readState());
      } catch (error) {
        _controller.add(VpnConnectionState(status: VpnConnectionStatus.error, errorMessage: error.toString()));
      }
    });
    Future(() async => _controller.add(await _readState()));
    return _controller.stream;
  }

  @override
  Future<List<VpnServer>> listServers({required String providerId}) async {
    await _ensureInitialized();
    final input = _utf8(providerId);
    try {
      final raw = jsonDecode(_readOwned(_listServers(input))) as List<dynamic>;
      return raw.cast<Map<String, dynamic>>().map((item) => VpnServer(
        id: item['id'] as String,
        providerId: (item['provider_id'] as String?) ?? providerId,
        country: item['country'] as String,
        city: item['city'] as String,
        hostname: item['hostname'] as String,
        latencyMs: item['latency_ms'] as int?,
      )).toList(growable: false);
    } finally {
      malloc.free(input);
    }
  }

  @override
  Future<void> refreshServers({required String providerId}) async {
    await _ensureInitialized();
    final source = _catalogUrl(providerId);
    if (source == null) return;
    final catalogJson = await _downloadCatalog(Uri.parse(source));
    final result = await _applyCatalogJson(providerId, catalogJson);
    if (result['ok'] != true) {
      throw StateError((result['error'] as String?) ?? 'Catalog update rejected');
    }
  }

  @override
  Future<void> connect({required String providerId, VpnServer? server, required String protocol}) async {
    await _ensureInitialized();
    final servers = await listServers(providerId: providerId);
    if (servers.isEmpty) throw StateError('No valid bundled or cached servers are available.');
    final selected = server ?? servers.first;
    final p = _utf8(providerId);
    final l = _utf8(selected.id);
    final proto = _utf8(protocol.toLowerCase());
    try {
      final result = _jsonObject(_connect(p, l, proto));
      if (result['ok'] != true) throw StateError((result['error'] as String?) ?? 'Native connect failed');
      _controller.add(await _readState());
    } finally {
      malloc.free(p);
      malloc.free(l);
      malloc.free(proto);
    }
  }

  @override
  Future<void> disconnect() async {
    await _ensureInitialized();
    final result = _jsonObject(_disconnect());
    if (result['ok'] != true) throw StateError((result['error'] as String?) ?? 'Native disconnect failed');
    _controller.add(await _readState());
  }

  Future<void> _setFlag(_BoolDart fn, bool enabled) async {
    await _ensureInitialized();
    final result = _jsonObject(fn(enabled));
    if (result['ok'] != true) throw StateError((result['error'] as String?) ?? 'Native setting failed');
  }

  @override
  Future<void> setKillSwitch(bool enabled) => _setFlag(_setKillSwitch, enabled);
  @override
  Future<void> setDnsProtection(bool enabled) => _setFlag(_setDnsProtection, enabled);
  @override
  Future<void> setIpv6Protection(bool enabled) => _setFlag(_setIpv6Protection, enabled);

  @override
  Future<Map<String, Object?>> runDiagnostics() async {
    await _ensureInitialized();
    return Map<String, Object?>.from(_jsonObject(_diagnostics()))
      ..['library'] = _library.toString()
      ..['ffi_version'] = _readOwned(_version());
  }
}
