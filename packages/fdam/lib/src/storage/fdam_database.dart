// SQLite metadata store with versioned migrations.

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/errors.dart';
import '../manifest/models.dart';

/// Status of an asset on this device.
enum LocalAssetStatus {
  notInstalled('not_installed'),
  installed('installed'),
  failed('failed'),

  /// No longer in the manifest. Files are kept until the app says they are
  /// unused.
  removed('removed');

  const LocalAssetStatus(this.wire);
  final String wire;
  static LocalAssetStatus fromWire(String? s) =>
      values.firstWhere((e) => e.wire == s, orElse: () => LocalAssetStatus.notInstalled);
}

class LocalAssetRecord {
  const LocalAssetRecord({
    required this.id,
    required this.name,
    required this.category,
    required this.version,
    required this.localPath,
    required this.sizeBytes,
    required this.sha256,
    required this.status,
    this.downloadedAt,
    this.updatedAt,
    this.required = false,
    this.priority = 3,
    this.previousVersion,
    this.previousSha256,
    this.backupPath,
    this.inManifest = true,
    this.deprecated = false,
    this.extract = false,
  });

  final String id;
  final String name;
  final String category;
  final String version;

  /// Relative to the FDAM root.
  final String localPath;
  final int sizeBytes;
  final String sha256;
  final LocalAssetStatus status;
  final DateTime? downloadedAt;
  final DateTime? updatedAt;
  final bool required;
  final int priority;
  final String? previousVersion;
  final String? previousSha256;

  /// Relative path of the previous version kept for rollback.
  final String? backupPath;
  final bool inManifest;
  final bool deprecated;
  final bool extract;

  bool get isInstalled => status == LocalAssetStatus.installed;

  factory LocalAssetRecord.fromRow(Map<String, Object?> r) => LocalAssetRecord(
        id: r['id'] as String,
        name: r['name'] as String,
        category: r['category'] as String,
        version: r['version'] as String,
        localPath: r['local_path'] as String,
        sizeBytes: (r['size_bytes'] as int?) ?? 0,
        sha256: r['sha256'] as String,
        status: LocalAssetStatus.fromWire(r['status'] as String?),
        downloadedAt: _date(r['downloaded_at']),
        updatedAt: _date(r['updated_at']),
        required: r['required'] == 1,
        priority: (r['priority'] as int?) ?? 3,
        previousVersion: r['previous_version'] as String?,
        previousSha256: r['previous_sha256'] as String?,
        backupPath: r['backup_path'] as String?,
        inManifest: r['in_manifest'] != 0,
        deprecated: r['deprecated'] == 1,
        extract: r['extract'] == 1,
      );

  static DateTime? _date(Object? o) => o is String ? DateTime.tryParse(o) : null;
}

class DownloadRecord {
  const DownloadRecord({
    required this.assetId,
    required this.downloadUrl,
    required this.temporaryPath,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.status,
    required this.retryCount,
    this.lastError,
    this.etag,
    this.lastModified,
    this.version,
    this.sha256,
    this.priority = 3,
    this.createdAt,
    this.updatedAt,
  });

  final String assetId;
  final String downloadUrl;
  final String temporaryPath;
  final int downloadedBytes;
  final int totalBytes;
  final DownloadStatus status;
  final int retryCount;
  final String? lastError;
  final String? etag;
  final String? lastModified;
  final String? version;
  final String? sha256;
  final int priority;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory DownloadRecord.fromRow(Map<String, Object?> r) => DownloadRecord(
        assetId: r['asset_id'] as String,
        downloadUrl: r['download_url'] as String,
        temporaryPath: r['temporary_path'] as String,
        downloadedBytes: (r['downloaded_bytes'] as int?) ?? 0,
        totalBytes: (r['total_bytes'] as int?) ?? 0,
        status: DownloadStatus.fromName(r['status'] as String?),
        retryCount: (r['retry_count'] as int?) ?? 0,
        lastError: r['last_error'] as String?,
        etag: r['etag'] as String?,
        lastModified: r['last_modified'] as String?,
        version: r['version'] as String?,
        sha256: r['sha256'] as String?,
        priority: (r['priority'] as int?) ?? 3,
        createdAt: LocalAssetRecord._date(r['created_at']),
        updatedAt: LocalAssetRecord._date(r['updated_at']),
      );
}

/// Each entry upgrades the schema from (index) to (index + 1).
/// Never edit an existing migration; append a new one.
const List<List<String>> kFdamMigrations = [
  // v1: tables from the specification.
  [
    '''CREATE TABLE assets (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      category TEXT NOT NULL,
      version TEXT NOT NULL,
      local_path TEXT NOT NULL,
      size_bytes INTEGER NOT NULL DEFAULT 0,
      sha256 TEXT NOT NULL,
      status TEXT NOT NULL,
      downloaded_at TEXT,
      updated_at TEXT
    )''',
    '''CREATE TABLE downloads (
      id TEXT PRIMARY KEY,
      asset_id TEXT NOT NULL,
      download_url TEXT NOT NULL,
      temporary_path TEXT NOT NULL,
      downloaded_bytes INTEGER NOT NULL DEFAULT 0,
      total_bytes INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )''',
    '''CREATE TABLE app_settings (
      key TEXT PRIMARY KEY,
      value TEXT
    )''',
  ],
  // v2: version management, rollback and resume validation.
  [
    'ALTER TABLE assets ADD COLUMN required INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE assets ADD COLUMN priority INTEGER NOT NULL DEFAULT 3',
    'ALTER TABLE assets ADD COLUMN previous_version TEXT',
    'ALTER TABLE assets ADD COLUMN previous_sha256 TEXT',
    'ALTER TABLE assets ADD COLUMN backup_path TEXT',
    'ALTER TABLE assets ADD COLUMN in_manifest INTEGER NOT NULL DEFAULT 1',
    'ALTER TABLE assets ADD COLUMN deprecated INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE assets ADD COLUMN extract INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE downloads ADD COLUMN etag TEXT',
    'ALTER TABLE downloads ADD COLUMN last_modified TEXT',
    'ALTER TABLE downloads ADD COLUMN version TEXT',
    'ALTER TABLE downloads ADD COLUMN sha256 TEXT',
    'ALTER TABLE downloads ADD COLUMN priority INTEGER NOT NULL DEFAULT 3',
    'CREATE UNIQUE INDEX idx_downloads_asset ON downloads(asset_id)',
    'CREATE INDEX idx_downloads_status ON downloads(status)',
  ],
];

int get kFdamDbVersion => kFdamMigrations.length;

class FdamDatabase {
  FdamDatabase._(this.db);

  final Database db;

  static Future<FdamDatabase> open(String path, {DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    try {
      final db = await f.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: kFdamDbVersion,
          onConfigure: (db) async {
            // WAL keeps the DB consistent if the app is killed mid-write.
            // Not allowed inside a transaction on some sqflite builds, so ignore failures.
            try {
              await db.rawQuery('PRAGMA journal_mode=WAL');
            } catch (_) {}
          },
          onCreate: (db, version) => _migrate(db, 0, version),
          onUpgrade: _migrate,
          onDowngrade: (db, oldV, newV) => throw StateError('FDAM database v$oldV is newer than this app (v$newV)'),
        ),
      );
      return FdamDatabase._(db);
    } catch (e) {
      throw FdamException(FdamErrorCode.databaseError, 'open failed: ${e.runtimeType}: $e');
    }
  }

  static Future<void> _migrate(Database db, int from, int to) async {
    for (var v = from; v < to; v++) {
      final batch = db.batch();
      for (final sql in kFdamMigrations[v]) {
        batch.execute(sql);
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> close() => db.close();

  Future<T> _guard<T>(String op, Future<T> Function() f) async {
    try {
      return await f();
    } on FdamException {
      rethrow;
    } catch (e) {
      throw FdamException(FdamErrorCode.databaseError, '$op: ${e.runtimeType}: $e');
    }
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();

  // ---- assets -------------------------------------------------------------

  Future<List<LocalAssetRecord>> allAssets() => _guard('allAssets', () async {
        final rows = await db.query('assets', orderBy: 'priority, id');
        return rows.map(LocalAssetRecord.fromRow).toList();
      });

  Future<LocalAssetRecord?> asset(String id) => _guard('asset', () async {
        final rows = await db.query('assets', where: 'id = ?', whereArgs: [id], limit: 1);
        return rows.isEmpty ? null : LocalAssetRecord.fromRow(rows.first);
      });

  /// Inserts or replaces the record for an installed asset.
  Future<void> recordInstalled(
    AssetItem item, {
    required String localPath,
    required int sizeOnDisk,
    String? previousVersion,
    String? previousSha256,
    String? backupPath,
    Transaction? txn,
  }) =>
      _guard('recordInstalled', () async {
        final now = _now();
        final values = {
          'id': item.id,
          'name': item.name,
          'category': item.category.wireName,
          'version': item.version,
          'local_path': localPath,
          'size_bytes': sizeOnDisk,
          'sha256': item.sha256,
          'status': LocalAssetStatus.installed.wire,
          'downloaded_at': now,
          'updated_at': now,
          'required': item.required ? 1 : 0,
          'priority': item.priority.level,
          'previous_version': previousVersion,
          'previous_sha256': previousSha256,
          'backup_path': backupPath,
          'in_manifest': 1,
          'deprecated': item.deprecated ? 1 : 0,
          'extract': item.extract ? 1 : 0,
        };
        await (txn ?? db).insert('assets', values, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  Future<void> updateAssetStatus(String id, LocalAssetStatus status) => _guard('updateAssetStatus', () async {
        await db.update('assets', {'status': status.wire, 'updated_at': _now()}, where: 'id = ?', whereArgs: [id]);
      });

  /// Marks manifest membership / flags without touching installed files.
  Future<void> syncManifestFlags(AssetManifest manifest) => _guard('syncManifestFlags', () async {
        await db.transaction((txn) async {
          final ids = manifest.assets.map((a) => a.id).toSet();
          final rows = await txn.query('assets', columns: ['id']);
          for (final r in rows) {
            final id = r['id'] as String;
            final item = manifest.byId(id);
            if (item == null) {
              await txn.update(
                  'assets', {'in_manifest': 0, 'status': LocalAssetStatus.removed.wire, 'updated_at': _now()},
                  where: 'id = ? AND status = ?', whereArgs: [id, LocalAssetStatus.installed.wire]);
              await txn.update('assets', {'in_manifest': 0}, where: 'id = ?', whereArgs: [id]);
            } else {
              await txn.update(
                  'assets',
                  {
                    'in_manifest': 1,
                    'required': item.required ? 1 : 0,
                    'priority': item.priority.level,
                    'deprecated': item.deprecated ? 1 : 0,
                  },
                  where: 'id = ?',
                  whereArgs: [id]);
              // An asset that came back into the manifest is installed again.
              await txn.update('assets', {'status': LocalAssetStatus.installed.wire},
                  where: 'id = ? AND status = ?', whereArgs: [id, LocalAssetStatus.removed.wire]);
            }
          }
          // Drop download rows for assets that left the manifest.
          final dl = await txn.query('downloads', columns: ['asset_id']);
          for (final r in dl) {
            if (!ids.contains(r['asset_id'])) {
              await txn.delete('downloads', where: 'asset_id = ?', whereArgs: [r['asset_id']]);
            }
          }
        });
      });

  Future<void> deleteAssetRecord(String id) => _guard('deleteAssetRecord', () async {
        await db.delete('assets', where: 'id = ?', whereArgs: [id]);
      });

  // ---- downloads ----------------------------------------------------------

  Future<DownloadRecord?> download(String assetId) => _guard('download', () async {
        final rows = await db.query('downloads', where: 'asset_id = ?', whereArgs: [assetId], limit: 1);
        return rows.isEmpty ? null : DownloadRecord.fromRow(rows.first);
      });

  Future<List<DownloadRecord>> allDownloads() => _guard('allDownloads', () async {
        final rows = await db.query('downloads', orderBy: 'priority, created_at');
        return rows.map(DownloadRecord.fromRow).toList();
      });

  Future<void> upsertDownload({
    required AssetItem item,
    required String temporaryPath,
    required int downloadedBytes,
    required DownloadStatus status,
    int? retryCount,
    String? lastError,
    String? etag,
    String? lastModified,
    bool clearValidators = false,
  }) =>
      _guard('upsertDownload', () async {
        final now = _now();
        await db.transaction((txn) async {
          final existing =
              await txn.query('downloads', where: 'asset_id = ?', whereArgs: [item.id], limit: 1);
          final values = <String, Object?>{
            'download_url': item.url,
            'temporary_path': temporaryPath,
            'downloaded_bytes': downloadedBytes,
            'total_bytes': item.sizeBytes,
            'status': status.name,
            'version': item.version,
            'sha256': item.sha256,
            'priority': item.priority.level,
            'updated_at': now,
            'last_error': lastError,
          };
          if (retryCount != null) values['retry_count'] = retryCount;
          if (clearValidators) {
            values['etag'] = null;
            values['last_modified'] = null;
          }
          if (etag != null) values['etag'] = etag;
          if (lastModified != null) values['last_modified'] = lastModified;
          if (existing.isEmpty) {
            await txn.insert('downloads', {
              'id': item.id,
              'asset_id': item.id,
              'created_at': now,
              'retry_count': retryCount ?? 0,
              ...values,
            });
          } else {
            await txn.update('downloads', values, where: 'asset_id = ?', whereArgs: [item.id]);
          }
        });
      });

  Future<void> deleteDownload(String assetId) => _guard('deleteDownload', () async {
        await db.delete('downloads', where: 'asset_id = ?', whereArgs: [assetId]);
      });

  // ---- settings -----------------------------------------------------------

  Future<String?> getSetting(String key) => _guard('getSetting', () async {
        final rows = await db.query('app_settings', where: 'key = ?', whereArgs: [key], limit: 1);
        return rows.isEmpty ? null : rows.first['value'] as String?;
      });

  Future<void> setSetting(String key, String? value) => _guard('setSetting', () async {
        if (value == null) {
          await db.delete('app_settings', where: 'key = ?', whereArgs: [key]);
        } else {
          await db.insert('app_settings', {'key': key, 'value': value},
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      });

  Future<Map<String, String>> settingsWithPrefix(String prefix) => _guard('settingsWithPrefix', () async {
        final rows = await db.query('app_settings', where: 'key LIKE ?', whereArgs: ['$prefix%']);
        return {for (final r in rows) r['key'] as String: (r['value'] as String?) ?? ''};
      });

  Future<Map<String, dynamic>?> getJson(String key) async {
    final s = await getSetting(key);
    if (s == null) return null;
    try {
      return (jsonDecode(s) as Map).cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  Future<void> setJson(String key, Map<String, dynamic>? value) =>
      setSetting(key, value == null ? null : jsonEncode(value));
}
