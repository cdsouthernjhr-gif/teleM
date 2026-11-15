// GitHub-hosted JSON database with offline cache and bundled fallback.
//
// Update flow (spec §11):
//  1. Read the current database (cache → bundled asset).
//  2. Download app_config.json from GitHub and compare database_version.
//  3. If newer (or a manual update is forced) download all documents.
//  4. Validate the structure with [SchemaValidator].
//  5. Save the new cache atomically.
//  6. On any failure keep the old cache untouched.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/diagnostics.dart';
import 'models.dart';
import 'schema_validator.dart';

/// Abstract key/value store for the cached database (file based in the app,
/// in-memory in tests).
abstract class CacheStore {
  Future<String?> read();
  Future<void> write(String contents);
}

class FileCacheStore implements CacheStore {
  FileCacheStore(this.file);
  final File file;

  @override
  Future<String?> read() async {
    try {
      if (await file.exists()) return await file.readAsString();
    } catch (e) {
      diag.warn('db', 'cache read failed: $e');
    }
    return null;
  }

  /// Writes to a temporary file and renames it so a crash mid-write never
  /// corrupts the existing cache.
  @override
  Future<void> write(String contents) async {
    final tmp = File('${file.path}.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(file.path);
  }
}

class MemoryCacheStore implements CacheStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String contents) async => value = contents;
}

typedef AssetReader = Future<String> Function(String path);

enum DatabaseSource { remote, cache, bundled }

enum UpdateOutcome { updated, upToDate, failedNetwork, failedInvalid, appTooOld }

class UpdateResult {
  UpdateResult(this.outcome, {this.message = '', this.newVersion});
  final UpdateOutcome outcome;
  final String message;
  final int? newVersion;

  bool get changed => outcome == UpdateOutcome.updated;
}

class DatabaseRepository {
  DatabaseRepository({
    required this.client,
    required this.cache,
    required this.readAsset,
    required this.baseUrl,
    this.appBuild = 1,
    this.timeout = const Duration(seconds: 15),
    this.maxFileBytes = 2 * 1024 * 1024,
  });

  final http.Client client;
  final CacheStore cache;
  final AssetReader readAsset;

  /// e.g. https://raw.githubusercontent.com/OWNER/REPO/main/database/
  final String baseUrl;
  final int appBuild;
  final Duration timeout;
  final int maxFileBytes;

  DatabaseBundle? _current;
  DatabaseSource? _source;

  DatabaseBundle? get current => _current;
  DatabaseSource? get source => _source;

  /// Repository root URL (one level above `database/`), used for logos.
  String get repoRootUrl {
    final b = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    return b.endsWith('database/') ? b.substring(0, b.length - 'database/'.length) : b;
  }

  static Map<String, Map<String, dynamic>?> _decodeAll(Map<String, String> texts) {
    final out = <String, Map<String, dynamic>?>{};
    for (final f in DatabaseBundle.fileNames) {
      final t = texts[f];
      try {
        final v = t == null ? null : jsonDecode(t);
        out[f] = v is Map<String, dynamic> ? v : null;
      } catch (_) {
        out[f] = null;
      }
    }
    return out;
  }

  static DatabaseBundle? _bundleIfValid(Map<String, Map<String, dynamic>?> raw, String label) {
    final report = SchemaValidator.validate(raw);
    if (!report.isValid) {
      diag.warn('db', '$label invalid: ${report.errors.take(5).join("; ")}');
      return null;
    }
    return DatabaseBundle.fromRaw(raw.map((k, v) => MapEntry(k, v!)));
  }

  /// Loads the best local database: valid cache, otherwise bundled assets.
  Future<DatabaseBundle> loadLocal() async {
    final cached = await cache.read();
    if (cached != null) {
      try {
        final m = jsonDecode(cached);
        if (m is Map<String, dynamic>) {
          final raw = <String, Map<String, dynamic>?>{
            for (final f in DatabaseBundle.fileNames)
              f: m[f] is Map<String, dynamic> ? m[f] as Map<String, dynamic> : null,
          };
          final b = _bundleIfValid(raw, 'cache');
          if (b != null) {
            _current = b;
            _source = DatabaseSource.cache;
            diag.info('db', 'loaded cache v${b.version}');
            return b;
          }
        }
      } catch (e) {
        diag.warn('db', 'cache corrupt: $e');
      }
    }
    final texts = <String, String>{};
    for (final f in DatabaseBundle.fileNames) {
      texts[f] = await readAsset('database/$f');
    }
    final b = _bundleIfValid(_decodeAll(texts), 'bundled');
    if (b == null) {
      throw StateError('Bundled database is invalid - the build is broken.');
    }
    _current = b;
    _source = DatabaseSource.bundled;
    diag.info('db', 'loaded bundled v${b.version}');
    return b;
  }

  Future<String> _fetch(String file) async {
    final b = baseUrl.endsWith('/') ? baseUrl : '$baseUrl/';
    // Cache-buster so the GitHub CDN does not serve a stale copy after an edit.
    final uri = Uri.parse('$b$file').replace(queryParameters: {
      't': (DateTime.now().millisecondsSinceEpoch ~/ 60000).toString(),
    });
    final req = http.Request('GET', uri)..headers['Accept'] = 'application/json';
    final resp = await client.send(req).timeout(timeout);
    if (resp.statusCode != 200) {
      await resp.stream.drain<void>();
      throw HttpException('HTTP ${resp.statusCode} for $file');
    }
    final bytes = <int>[];
    await for (final chunk in resp.stream.timeout(timeout)) {
      bytes.addAll(chunk);
      if (bytes.length > maxFileBytes) throw HttpException('$file exceeds size limit');
    }
    return utf8.decode(bytes);
  }

  /// Checks GitHub for a newer database. When [force] is true (MANUAL UPDATE)
  /// all files are downloaded even if the version number is unchanged.
  Future<UpdateResult> checkForUpdate({bool force = false}) async {
    final current = _current ?? await loadLocal();
    String cfgText;
    try {
      cfgText = await _fetch('app_config.json');
    } catch (e) {
      diag.warn('db', 'update check failed: $e');
      return UpdateResult(UpdateOutcome.failedNetwork, message: e.toString());
    }
    Map<String, dynamic>? cfg;
    try {
      final v = jsonDecode(cfgText);
      if (v is Map<String, dynamic>) cfg = v;
    } catch (_) {}
    if (cfg == null) {
      return UpdateResult(UpdateOutcome.failedInvalid, message: 'app_config.json is not valid JSON');
    }
    final remoteVersion = (cfg['database_version'] as num?)?.toInt() ?? 0;
    final minBuild = (cfg['min_app_build'] as num?)?.toInt() ?? 1;
    if (minBuild > appBuild) {
      diag.warn('db', 'remote database needs app build $minBuild (have $appBuild)');
      return UpdateResult(UpdateOutcome.appTooOld, newVersion: remoteVersion);
    }
    if (!force && remoteVersion <= current.version) {
      diag.info('db', 'up to date (v${current.version})');
      return UpdateResult(UpdateOutcome.upToDate, newVersion: remoteVersion);
    }

    final texts = <String, String>{'app_config.json': cfgText};
    try {
      for (final f in DatabaseBundle.fileNames.where((f) => f != 'app_config.json')) {
        texts[f] = await _fetch(f);
      }
    } catch (e) {
      diag.warn('db', 'download failed, keeping v${current.version}: $e');
      return UpdateResult(UpdateOutcome.failedNetwork, message: e.toString());
    }
    final raw = _decodeAll(texts);
    final report = SchemaValidator.validate(raw);
    if (!report.isValid) {
      diag.error('db', 'remote database rejected: ${report.errors.take(5).join("; ")}');
      return UpdateResult(UpdateOutcome.failedInvalid,
          message: report.errors.take(3).join('\n'), newVersion: remoteVersion);
    }
    final bundle = DatabaseBundle.fromRaw(raw.map((k, v) => MapEntry(k, v!)));
    try {
      await cache.write(jsonEncode(bundle.raw));
    } catch (e) {
      diag.error('db', 'cache write failed: $e');
      // Still use the new data for this session.
    }
    final changed = bundle.version != current.version || _source == DatabaseSource.bundled || force;
    _current = bundle;
    _source = DatabaseSource.remote;
    diag.info('db', 'updated to v${bundle.version}');
    return UpdateResult(changed ? UpdateOutcome.updated : UpdateOutcome.upToDate,
        newVersion: bundle.version);
  }
}
