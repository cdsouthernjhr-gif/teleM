// Read/write access to installed assets for the host app.

import '../core/errors.dart';
import '../install/asset_installer.dart';
import '../manifest/models.dart';
import 'fdam_database.dart';
import 'fdam_paths.dart';

/// Returns true when the app still uses an asset that is no longer in the
/// manifest. Such files are never deleted automatically.
typedef AssetUsageChecker = Future<bool> Function(LocalAssetRecord record);

Future<bool> assumeInUse(LocalAssetRecord _) async => true;

class AssetRepository {
  AssetRepository({required this.db, required this.paths, required this.installer, this.isInUse = assumeInUse});

  final FdamDatabase db;
  final FdamPaths paths;
  final AssetInstaller installer;
  AssetUsageChecker isInUse;

  Future<List<LocalAssetRecord>> getAllAssets() => db.allAssets();

  Future<LocalAssetRecord?> getAssetById(String id) => db.asset(id);

  /// Installed and files present on disk.
  Future<bool> isAssetDownloaded(String id) async {
    final r = await db.asset(id);
    if (r == null || r.status == LocalAssetStatus.notInstalled || r.status == LocalAssetStatus.failed) {
      return false;
    }
    return installer.filesPresent(r);
  }

  Future<String?> getAssetVersion(String id) async => (await db.asset(id))?.version;

  /// Absolute path of the installed file (or extracted directory), or null
  /// when the asset is not available.
  Future<String?> getAssetLocalPath(String id) async {
    final r = await db.asset(id);
    if (r == null || (r.status != LocalAssetStatus.installed && r.status != LocalAssetStatus.removed)) return null;
    return paths.toAbsolute(r.localPath);
  }

  Future<void> updateAssetStatus(String id, LocalAssetStatus status) => db.updateAssetStatus(id, status);

  /// Deletes an asset's files. Required assets and assets the app reports as
  /// in use are refused unless [force] is set.
  Future<bool> deleteAsset(String id, {bool force = false}) async {
    final r = await db.asset(id);
    if (r == null) return false;
    if (!force) {
      if (r.required && r.inManifest) {
        throw FdamException(FdamErrorCode.versionConflict, '$id is required and cannot be deleted');
      }
      if (!r.inManifest && await isInUse(r)) return false;
    }
    await installer.uninstall(id);
    return true;
  }

  /// Bytes used by installed assets.
  Future<int> getDownloadedSize() async {
    final all = await db.allAssets();
    return all
        .where((r) => r.status == LocalAssetStatus.installed || r.status == LocalAssetStatus.removed)
        .fold<int>(0, (s, r) => s + r.sizeBytes);
  }

  /// Download size of all required assets in [manifest].
  int getTotalRequiredSize(AssetManifest manifest) => manifest.totalRequiredBytes;

  /// Deletes files of assets removed from the manifest that the app says it
  /// no longer uses. Returns the ids deleted.
  Future<List<String>> cleanupRemoved() async {
    final out = <String>[];
    for (final r in await db.allAssets()) {
      if (r.inManifest) continue;
      if (await isInUse(r)) continue;
      await installer.uninstall(r.id);
      out.add(r.id);
    }
    return out;
  }
}
