// User data stored on the device: favourites, watch history, last channel,
// settings and cached health results. No credentials are ever stored.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/geo_service.dart';
import '../services/stream_health_checker.dart';

class HistoryEntry {
  HistoryEntry(this.channelId, this.at);
  final String channelId;
  final DateTime at;
}

class LocalStore {
  LocalStore(this._p);
  final SharedPreferences _p;

  static Future<LocalStore> open() async => LocalStore(await SharedPreferences.getInstance());

  static const _kFav = 'favourites';
  static const _kHistory = 'history';
  static const _kLast = 'last_channel';
  static const _kLang = 'language';
  static const _kGeoEnabled = 'geo_enabled';
  static const _kGeo = 'geo_info';
  static const _kCountry = 'selected_country';
  static const _kHealth = 'health_results';
  static const _kLastOk = 'last_success';
  static const _kLastUpdate = 'last_update_check';
  static const maxHistory = 30;

  // Favourites
  List<String> get favourites => _p.getStringList(_kFav) ?? const [];
  bool isFavourite(String id) => favourites.contains(id);
  Future<void> toggleFavourite(String id) async {
    final f = List<String>.from(favourites);
    f.contains(id) ? f.remove(id) : f.add(id);
    await _p.setStringList(_kFav, f);
  }

  // History
  List<HistoryEntry> get history {
    final raw = _p.getStringList(_kHistory) ?? const [];
    return raw
        .map((s) {
          final i = s.indexOf('|');
          if (i < 0) return null;
          final t = DateTime.tryParse(s.substring(i + 1));
          return t == null ? null : HistoryEntry(s.substring(0, i), t);
        })
        .whereType<HistoryEntry>()
        .toList();
  }

  Future<void> addHistory(String id) async {
    final list = history.where((h) => h.channelId != id).toList()..insert(0, HistoryEntry(id, DateTime.now()));
    await _p.setStringList(
        _kHistory, list.take(maxHistory).map((h) => '${h.channelId}|${h.at.toIso8601String()}').toList());
    await _p.setString(_kLast, id);
  }

  Future<void> clearHistory() async {
    await _p.remove(_kHistory);
  }

  String? get lastChannel => _p.getString(_kLast);

  // Settings
  String get language => _p.getString(_kLang) ?? 'ms';
  Future<void> setLanguage(String l) => _p.setString(_kLang, l);

  bool get geoEnabled => _p.getBool(_kGeoEnabled) ?? true;
  Future<void> setGeoEnabled(bool v) => _p.setBool(_kGeoEnabled, v);

  GeoInfo? get geoInfo {
    final s = _p.getString(_kGeo);
    if (s == null) return null;
    try {
      return GeoInfo.fromJson(jsonDecode(s));
    } catch (_) {
      return null;
    }
  }

  Future<void> setGeoInfo(GeoInfo? g) async =>
      g == null ? _p.remove(_kGeo) : _p.setString(_kGeo, jsonEncode(g.toJson()));

  String? get selectedCountry => _p.getString(_kCountry);
  Future<void> setSelectedCountry(String c) => _p.setString(_kCountry, c);

  DateTime? get lastUpdateCheck => DateTime.tryParse(_p.getString(_kLastUpdate) ?? '');
  Future<void> setLastUpdateCheck(DateTime t) => _p.setString(_kLastUpdate, t.toIso8601String());

  // Health results (from on-device checks / playback)
  Map<String, HealthResult> get healthResults {
    final s = _p.getString(_kHealth);
    if (s == null) return {};
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      final out = <String, HealthResult>{};
      m.forEach((k, v) {
        final r = HealthResult.fromJson(v);
        if (r != null) out[k] = r;
      });
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveHealthResults(Map<String, HealthResult> m) =>
      _p.setString(_kHealth, jsonEncode(m.map((k, v) => MapEntry(k, v.toJson()))));

  Map<String, DateTime> get lastSuccessfulPlayback {
    final s = _p.getString(_kLastOk);
    if (s == null) return {};
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, DateTime.tryParse(v.toString()) ?? DateTime(2000)));
    } catch (_) {
      return {};
    }
  }

  Future<void> recordSuccess(String id) async {
    final m = lastSuccessfulPlayback..[id] = DateTime.now();
    await _p.setString(_kLastOk, jsonEncode(m.map((k, v) => MapEntry(k, v.toIso8601String()))));
  }
}
