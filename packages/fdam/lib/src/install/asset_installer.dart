// Installs a verified download: extract/move into staging, then swap into the
// production location. The old version is moved to backups/ first and is
// restored if anything fails, so a failed update never loses the old files.
// A journal row in app_settings makes the swap recoverable after a crash.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/logger.dart';
import '../extract/zip_extractor.dart';
import '../manifest/models.dart';
import '../storage/fdam_database.dart';
import '../storage/fdam_paths.dart';
import '../storage/storage_info.dart';

const String kInstallMarker = '.fdam.json';
const String _journalPrefix = 'journal:';
const String kSkipPrefix = 'skip_sha:';

typedef ActivationHook = Future<void> Function(AssetItem item);

class AssetInstaller {
  AssetInstaller({
    required this.config,
    required this.paths,
    required this.db,
    required this.storage,
    ZipExtractor? extractor,
    FdamLogger? logger,
    this.beforeActivate,
    this.afterActivate,
  })  : extractor = extractor ?? ZipExtractor(limits: config.zipLimits),
        log = logger ?? FdamLogger();

  final FdamConfig config;
  final FdamPaths paths;
  final FdamDatabase db;
  final StorageInfoProvider storage;
  final ZipExtractor extractor;
  final FdamLogger log;

  /// Called before an installed asset is replaced (e.g. close a SQLite file
  /// the app has open) and after the new one is active.
  ActivationHook? beforeActivate;
  ActivationHook? afterActivate;

  /// Installs [item] from the verified file at [verifiedFile].
  Future<LocalAssetRecord> install(AssetItem item, String verifiedFile,
      {void Function(ZipProgress)? onExtractProgress}) async {
    final target = paths.installPath(item);
    final stage = paths.stagingDir(item);
    final old = await db.asset(item.id);
    String staged;
    int size;

    // 1. Prepare everything in staging.
    try {
      if (item.extract) {
        final space = await storage.spaceFor(paths.root.path);
        final r = await extractor.extract(
          verifiedFile,
          stage,
          availableBytes: space?.availableBytes,
          safetyMarginBytes: config.storageSafetyMarginBytes,
          onProgress: onExtractProgress,
        );
        await File(p.join(stage, kInstallMarker)).writeAsString(jsonEncode({
          'id': item.id,
          'version': item.version,
          'sha256': item.sha256,
          'files': r.fileCount,
          'bytes': r.totalBytes,
        }));
        staged = stage;
        size = r.totalBytes;
      } else {
        await Directory(stage).create(recursive: true);
        staged = p.join(stage, p.basename(target));
        await _move(verifiedFile, staged);
        size = await File(staged).length();
        if (size != item.sizeBytes) {
          throw FdamException(FdamErrorCode.checksumMismatch, 'staged size changed');
        }
      }
    } catch (e) {
      await deletePath(stage);
      if (e is FdamException) rethrow;
      throw FdamException(FdamErrorCode.unknown, 'staging failed: ${e.runtimeType}: $e');
    }

    // 2. Swap into place, keeping the old version as a backup.
    final backup = paths.backupPath(item.id, old?.version ?? 'previous');
    final hadOld = await pathExists(target);
    final journalKey = '$_journalPrefix${item.id}';
    await db.setJson(journalKey, {
      'target': paths.toRelative(target),
      'backup': paths.toRelative(backup),
      'staged': paths.toRelative(staged),
      'stage': paths.toRelative(stage),
      'version': item.version,
      'sha256': item.sha256,
      'hadOld': hadOld,
    });
    var movedOld = false;
    try {
      if (hadOld) {
        await beforeActivate?.call(item);
        await deletePath(backup);
        await Directory(p.dirname(backup)).create(recursive: true);
        await _move(target, backup);
        movedOld = true;
      }
      await Directory(p.dirname(target)).create(recursive: true);
      await _move(staged, target);
    } catch (e) {
      log.error('install', '${item.id}: activation failed, restoring old version: $e');
      if (await pathExists(target) && movedOld) await deletePath(target);
      if (movedOld) await _move(backup, target);
      await deletePath(stage);
      await db.setJson(journalKey, null);
      if (e is FdamException) rethrow;
      throw FdamException(FdamErrorCode.unknown, 'activation failed: ${e.runtimeType}');
    }

    // 3. Commit metadata. If that fails, undo the swap.
    try {
      await db.recordInstalled(
        item,
        localPath: paths.toRelative(target),
        sizeOnDisk: size,
        previousVersion: hadOld ? old?.version : null,
        previousSha256: hadOld ? old?.sha256 : null,
        backupPath: hadOld && config.keepBackups ? paths.toRelative(backup) : null,
      );
    } catch (e) {
      log.error('install', '${item.id}: database update failed, reverting: $e');
      await deletePath(target);
      if (movedOld) await _move(backup, target);
      await deletePath(stage);
      try {
        await db.setJson(journalKey, null);
      } catch (_) {}
      rethrow;
    }

    // 4. Clean up.
    await db.setJson(journalKey, null);
    await db.setSetting('$kSkipPrefix${item.id}', null);
    await deletePath(stage);
    await deletePath(verifiedFile);
    await db.deleteDownload(item.id);
    await _pruneBackups(item.id, keep: hadOld && config.keepBackups ? backup : null);
    try {
      await afterActivate?.call(item);
    } catch (e) {
      log.warn('install', '${item.id}: afterActivate hook failed: $e');
    }
    log.info('install', '${item.id} ${item.version} installed ($size bytes)');
    return (await db.asset(item.id))!;
  }

  /// Restores the previous version kept in backups/. The current files are
  /// deleted. The rolled-back-from SHA is remembered so the next update
  /// check does not immediately reinstall the same version.
  Future<LocalAssetRecord> rollback(String assetId) async {
    final rec = await db.asset(assetId);
    if (rec == null || rec.backupPath == null || rec.previousVersion == null || rec.previousSha256 == null) {
      throw FdamException(FdamErrorCode.versionConflict, 'no previous version kept for $assetId');
    }
    final backup = paths.toAbsolute(rec.backupPath!);
    if (!await pathExists(backup)) {
      throw FdamException(FdamErrorCode.fileNotFound, 'backup for $assetId is missing');
    }
    final target = paths.toAbsolute(rec.localPath);
    final trash = p.join(paths.staging.path, '$assetId-rollback-${DateTime.now().microsecondsSinceEpoch}');
    final hadTarget = await pathExists(target);
    if (hadTarget) await _move(target, trash);
    try {
      await _move(backup, target);
    } catch (e) {
      if (hadTarget) await _move(trash, target);
      throw FdamException(FdamErrorCode.unknown, 'rollback move failed: $e');
    }
    final size = await pathSize(target);
    try {
      await db.db.update(
        'assets',
        {
          'version': rec.previousVersion,
          'sha256': rec.previousSha256,
          'size_bytes': size,
          'status': LocalAssetStatus.installed.wire,
          'previous_version': null,
          'previous_sha256': null,
          'backup_path': null,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [assetId],
      );
    } catch (e) {
      await _move(target, backup);
      if (hadTarget) await _move(trash, target);
      throw FdamException(FdamErrorCode.databaseError, 'rollback: $e');
    }
    await db.setSetting('$kSkipPrefix$assetId', rec.sha256);
    await deletePath(trash);
    log.info('install', '$assetId rolled back ${rec.version} -> ${rec.previousVersion}');
    return (await db.asset(assetId))!;
  }

  /// Completes or undoes any swap interrupted by a crash, removes leftover
  /// staging data and orphaned .part files.
  Future<void> recover() async {
    final journals = await db.settingsWithPrefix(_journalPrefix);
    for (final entry in journals.entries) {
      final id = entry.key.substring(_journalPrefix.length);
      try {
        final j = (jsonDecode(entry.value) as Map).cast<String, dynamic>();
        final target = paths.toAbsolute(j['target'] as String);
        final backup = paths.toAbsolute(j['backup'] as String);
        final rec = await db.asset(id);
        final committed = rec != null &&
            rec.version == j['version'] &&
            rec.sha256 == j['sha256'] &&
            await pathExists(target);
        if (!committed) {
          final hadOld = j['hadOld'] == true;
          if (hadOld && await pathExists(backup)) {
            await deletePath(target);
            await _move(backup, target);
            log.warn('recover', '$id: interrupted update undone, previous version restored');
          } else if (!hadOld) {
            await deletePath(target);
          }
        }
      } catch (e) {
        log.error('recover', '$id: $e');
      }
      await db.setSetting(entry.key, null);
    }
    // Nothing is being installed during startup: staging can be emptied.
    if (await paths.staging.exists()) {
      await for (final e in paths.staging.list(followLinks: false)) {
        await deletePath(e.path);
      }
    }
    // .part files with no download row are orphans.
    final known = (await db.allDownloads()).map((d) => p.normalize(d.temporaryPath)).toSet();
    if (await paths.temp.exists()) {
      await for (final e in paths.temp.list(followLinks: false)) {
        if (!known.contains(p.normalize(e.path))) await deletePath(e.path);
      }
    }
  }

  /// Fast check that an installed asset's files are still there.
  Future<bool> filesPresent(LocalAssetRecord rec) async {
    try {
      final path = paths.toAbsolute(rec.localPath);
      if (rec.extract) {
        final marker = File(p.join(path, kInstallMarker));
        if (!await marker.exists()) return false;
        final m = jsonDecode(await marker.readAsString()) as Map;
        return m['sha256'] == rec.sha256;
      }
      final f = File(path);
      return await f.exists() && await f.length() == rec.sizeBytes;
    } catch (_) {
      return false;
    }
  }

  /// Deletes an asset's files, backups and record.
  Future<void> uninstall(String assetId) async {
    final rec = await db.asset(assetId);
    if (rec != null) {
      await deletePath(paths.toAbsolute(rec.localPath));
      if (rec.backupPath != null) await deletePath(paths.toAbsolute(rec.backupPath!));
    }
    await deletePath(p.join(paths.backups.path, assetId));
    await db.deleteAssetRecord(assetId);
    await db.deleteDownload(assetId);
  }

  Future<void> _pruneBackups(String assetId, {String? keep}) async {
    final dir = Directory(p.join(paths.backups.path, assetId));
    if (!await dir.exists()) return;
    await for (final e in dir.list(followLinks: false)) {
      if (keep == null || p.normalize(e.path) != p.normalize(keep)) await deletePath(e.path);
    }
    if (keep == null) await deletePath(dir.path);
  }

  /// Rename, falling back to copy+delete across file systems.
  static Future<void> _move(String from, String to) async {
    final type = await FileSystemEntity.type(from, followLinks: false);
    try {
      if (type == FileSystemEntityType.directory) {
        await Directory(from).rename(to);
      } else {
        await File(from).rename(to);
      }
    } on FileSystemException {
      if (type == FileSystemEntityType.directory) rethrow;
      await File(from).copy(to);
      await File(from).delete();
    }
  }
}
