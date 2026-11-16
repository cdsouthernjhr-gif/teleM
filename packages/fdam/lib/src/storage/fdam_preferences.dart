// User preferences (small values only) via shared_preferences.

import 'package:shared_preferences/shared_preferences.dart';

abstract class FdamPreferences {
  bool get wifiOnly;
  bool get autoUpdate;
  Future<void> setWifiOnly(bool v);
  Future<void> setAutoUpdate(bool v);

  /// Reloads values written by another isolate (background task).
  Future<void> reload();
}

class SharedFdamPreferences implements FdamPreferences {
  SharedFdamPreferences._(this._prefs, this.prefix);

  static Future<SharedFdamPreferences> load({String prefix = 'fdam.'}) async =>
      SharedFdamPreferences._(await SharedPreferences.getInstance(), prefix);

  final SharedPreferences _prefs;
  final String prefix;

  @override
  bool get wifiOnly => _prefs.getBool('${prefix}wifi_only') ?? false;
  @override
  bool get autoUpdate => _prefs.getBool('${prefix}auto_update') ?? true;
  @override
  Future<void> setWifiOnly(bool v) => _prefs.setBool('${prefix}wifi_only', v);
  @override
  Future<void> setAutoUpdate(bool v) => _prefs.setBool('${prefix}auto_update', v);
  @override
  Future<void> reload() => _prefs.reload();
}

class MemoryFdamPreferences implements FdamPreferences {
  MemoryFdamPreferences({this.wifiOnly = false, this.autoUpdate = true});
  @override
  bool wifiOnly;
  @override
  bool autoUpdate;
  @override
  Future<void> setWifiOnly(bool v) async => wifiOnly = v;
  @override
  Future<void> setAutoUpdate(bool v) async => autoUpdate = v;
  @override
  Future<void> reload() async {}
}
