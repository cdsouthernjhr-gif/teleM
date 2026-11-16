// Network state. connectivity_plus only tells which interface is up; a real
// HTTP request decides whether the internet actually works.

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';

import '../core/config.dart';
import '../core/logger.dart';
import 'fdam_http.dart';

enum NetworkKind { none, wifi, ethernet, mobile, other }

class NetworkState {
  const NetworkState(this.kind, this.internetReachable);
  final NetworkKind kind;

  /// Result of the last real request (null = not probed yet).
  final bool? internetReachable;

  bool get isUnmetered => kind == NetworkKind.wifi || kind == NetworkKind.ethernet;
  bool get hasInterface => kind != NetworkKind.none;
}

abstract class NetworkMonitor {
  NetworkState get current;
  Stream<NetworkState> get changes;

  /// Refreshes the interface type and makes a real request.
  Future<NetworkState> refresh();

  /// True when downloads may start now under [wifiOnly].
  Future<bool> canDownload({required bool wifiOnly}) async {
    final s = await refresh();
    if (s.internetReachable != true) return false;
    if (wifiOnly && !s.isUnmetered) return false;
    return true;
  }

  void dispose();
}

class ConnectivityNetworkMonitor extends NetworkMonitor {
  ConnectivityNetworkMonitor({required this.config, required this.http, Connectivity? connectivity, FdamLogger? logger})
      : _connectivity = connectivity ?? Connectivity(),
        log = logger ?? FdamLogger() {
    _sub = _connectivity.onConnectivityChanged.listen((r) async {
      final kind = _kindOf(r);
      if (kind == NetworkKind.none) {
        _set(const NetworkState(NetworkKind.none, false));
      } else {
        _set(NetworkState(kind, await _probe()));
      }
    }, onError: (_) {});
  }

  final FdamConfig config;
  final FdamHttp http;
  final Connectivity _connectivity;
  final FdamLogger log;
  late final StreamSubscription<List<ConnectivityResult>> _sub;
  final _changes = StreamController<NetworkState>.broadcast();
  NetworkState _current = const NetworkState(NetworkKind.other, null);
  DateTime? _lastProbe;

  @override
  NetworkState get current => _current;

  @override
  Stream<NetworkState> get changes => _changes.stream;

  void _set(NetworkState s) {
    final changed = s.kind != _current.kind || s.internetReachable != _current.internetReachable;
    _current = s;
    if (changed && !_changes.isClosed) _changes.add(s);
  }

  static NetworkKind _kindOf(List<ConnectivityResult> r) {
    if (r.contains(ConnectivityResult.wifi)) return NetworkKind.wifi;
    if (r.contains(ConnectivityResult.ethernet)) return NetworkKind.ethernet;
    if (r.contains(ConnectivityResult.mobile)) return NetworkKind.mobile;
    if (r.isEmpty || r.every((e) => e == ConnectivityResult.none)) return NetworkKind.none;
    return NetworkKind.other;
  }

  Future<bool> _probe() async {
    if (!config.isEnabled) return false;
    try {
      // HEAD avoids downloading the manifest; any HTTP answer proves the
      // internet works (404 included).
      final r = await http.getStream(config.probeUrl, head: true).timeout(const Duration(seconds: 8));
      await FdamHttp.discard(r);
      _lastProbe = DateTime.now();
      return true;
    } on DioException {
      return false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<NetworkState> refresh() async {
    NetworkKind kind;
    try {
      kind = _kindOf(await _connectivity.checkConnectivity());
    } catch (_) {
      kind = NetworkKind.other;
    }
    if (kind == NetworkKind.none) {
      _set(const NetworkState(NetworkKind.none, false));
      return _current;
    }
    // Avoid hammering the server when called in quick succession.
    final recent = _lastProbe != null &&
        DateTime.now().difference(_lastProbe!) < const Duration(seconds: 10) &&
        _current.internetReachable == true;
    _set(NetworkState(kind, recent ? true : await _probe()));
    return _current;
  }

  @override
  void dispose() {
    _sub.cancel();
    _changes.close();
  }
}

/// Manually controlled monitor, for tests and for hosts without
/// connectivity_plus.
class ManualNetworkMonitor extends NetworkMonitor {
  ManualNetworkMonitor({NetworkKind kind = NetworkKind.wifi, bool online = true})
      : _current = NetworkState(kind, online);

  NetworkState _current;
  final _changes = StreamController<NetworkState>.broadcast();

  void set(NetworkKind kind, bool online) {
    _current = NetworkState(kind, online);
    _changes.add(_current);
  }

  @override
  NetworkState get current => _current;
  @override
  Stream<NetworkState> get changes => _changes.stream;
  @override
  Future<NetworkState> refresh() async => _current;
  @override
  void dispose() => _changes.close();
}
