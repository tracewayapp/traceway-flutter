import 'dart:async';
import 'dart:io';

import '../guarded.dart';

/// The names of the network interfaces that are up with an address now.
typedef NetworkInterfaceLister = Future<List<String>> Function();

Future<List<String>> _listInterfaces() async => [
      for (final i in await NetworkInterface.list(
          includeLoopback: false, includeLinkLocal: false))
        if (i.addresses.isNotEmpty) i.name,
    ];

/// Whether the device is on an unmetered network (Wi-Fi, Ethernet), for the
/// `wifi` replay image policy, without a plugin: Flutter has no network
/// type API of its own.
///
/// The app's `TracewayOptions.isUnmeteredNetwork` decides when it is set.
/// Otherwise the network interfaces that have an address are looked at
/// ([unmeteredInterfaces]): Android `wlan*`/`eth*`, iOS `en0`, and the
/// Wi-Fi and Ethernet names of macOS, Linux and Windows. A phone on
/// cellular data has none of them up. A hotspot shared by another phone
/// looks like Wi-Fi to this heuristic; an app that needs to tell them apart
/// answers [TracewayOptions.isUnmeteredNetwork] itself (connectivity_plus,
/// say).
///
/// [unmetered] is asked on the capture's path, so it never waits: it answers
/// the last value known (metered until one is), and looks again in the
/// background when that value is older than [maxAge].
class NetworkState {
  NetworkState({
    FutureOr<bool> Function()? isUnmetered,
    NetworkInterfaceLister? interfaces,
    String? operatingSystem,
    this.maxAge = const Duration(seconds: 2),
    DateTime Function()? now,
  })  : _callback = isUnmetered,
        _interfaces = interfaces ?? _listInterfaces,
        _os = operatingSystem ?? Platform.operatingSystem,
        _now = now ?? DateTime.now;

  final FutureOr<bool> Function()? _callback;
  final NetworkInterfaceLister _interfaces;
  final String _os;
  final DateTime Function() _now;

  /// How old an answer may be before it is asked again.
  final Duration maxAge;

  bool _unmetered = false;
  DateTime? _checkedAt;
  bool _checking = false;

  /// Whether the network is unmetered, as last found; starts a new look in
  /// the background when that is stale. Never throws, never waits.
  bool unmetered() {
    final at = _checkedAt;
    if (at == null || _now().difference(at) >= maxAge) refresh();
    return _unmetered;
  }

  /// Looks at the network again. An answer the app's callback gives at
  /// once applies at once.
  void refresh() {
    if (_checking) return;
    _checking = true;
    _checkedAt = _now();
    final callback = _callback;
    final FutureOr<bool> answer;
    try {
      answer = callback != null ? callback() : _fromInterfaces();
    } catch (_) {
      // An app callback that throws says nothing: metered.
      _unmetered = false;
      _checking = false;
      return;
    }
    if (answer is bool) {
      _unmetered = answer;
      _checking = false;
      return;
    }
    final pending = Future<bool>.value(answer);
    unawaited(guardedAsync('network state', () async {
      try {
        _unmetered = await pending.timeout(const Duration(seconds: 5));
      } catch (_) {
        _unmetered = false;
      } finally {
        _checkedAt = _now();
        _checking = false;
      }
    }));
  }

  Future<bool> _fromInterfaces() async =>
      unmeteredInterfaces(await _interfaces(), _os);
}

/// Whether one of the interfaces named [names] (all up, with an address)
/// is a Wi-Fi or Ethernet one on [operatingSystem] (`Platform`'s name).
/// Cellular ones (`rmnet*`, `ccmni*`, `pdp_ip*`) and VPN tunnels never are.
bool unmeteredInterfaces(Iterable<String> names, String operatingSystem) {
  for (final raw in names) {
    final name = raw.toLowerCase();
    final unmetered = switch (operatingSystem) {
      'android' => name.startsWith('wlan') || name.startsWith('eth'),
      'ios' => name == 'en0',
      'macos' => name.startsWith('en'),
      'linux' => name.startsWith('wl') ||
          name.startsWith('eth') ||
          name.startsWith('en'),
      'windows' => name.contains('wi-fi') ||
          name.contains('wifi') ||
          name.contains('wlan') ||
          name.contains('wireless') ||
          name.contains('ethernet'),
      _ => false,
    };
    if (unmetered) return true;
  }
  return false;
}
