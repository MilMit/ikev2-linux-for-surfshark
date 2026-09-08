import 'dart:convert';
import 'dart:io';

class LinuxPlatformControls {
  static const _helper = '/usr/libexec/milmit-vpn-platform-helper';

  bool get supported => Platform.isLinux;

  Future<Map<String, dynamic>> _run(String action, [List<String> args = const []]) async {
    if (!Platform.isLinux) {
      throw UnsupportedError('Linux platform controls are only available on Linux.');
    }
    final result = await Process.run('pkexec', [_helper, action, ...args]);
    final output = '${result.stdout}'.trim().isNotEmpty ? '${result.stdout}'.trim() : '${result.stderr}'.trim();
    Map<String, dynamic> decoded;
    try {
      decoded = Map<String, dynamic>.from(jsonDecode(output) as Map);
    } catch (_) {
      throw StateError(output.isEmpty ? 'Platform helper returned no response.' : output);
    }
    if (result.exitCode != 0 || decoded['ok'] != true) {
      throw StateError((decoded['error'] as String?) ?? 'Linux platform operation failed.');
    }
    return decoded;
  }

  Future<void> setDnsProtection(bool enabled) => _run('dns-set', [enabled ? '1' : '0']);
  Future<void> setIpv6Protection(bool enabled) => _run('ipv6-set', [enabled ? '1' : '0']);
  Future<Map<String, dynamic>> splitStatus() => _run('split-status');
  Future<Map<String, dynamic>> setSplitEnabled(bool enabled) => _run('split-enable', [enabled ? '1' : '0']);
  Future<Map<String, dynamic>> addSplitRule(String target, String mode) => _run('split-add', [target, mode]);
  Future<Map<String, dynamic>> removeSplitRule(String target) => _run('split-remove', [target]);

  Future<List<Map<String, dynamic>>> listDesktopApps() async {
    final result = await _run('apps-list');
    return (result['apps'] as List? ?? const [])
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
  }

  Future<Map<String, dynamic>> launchAppDirect(String desktopId) =>
      _run('app-direct-launch', [desktopId]);
}
