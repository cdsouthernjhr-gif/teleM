// Directory layout under the app's private ApplicationSupportDirectory:
//
//   <root>/assets/{audio,images,videos,resources,config,data}
//   <root>/databases
//   <root>/staging     extraction / pre-activation area
//   <root>/temp        *.part download files
//   <root>/metadata    manifest_cache.json, fdam.db, logs
//   <root>/backups     previous version of each asset (rollback)

import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/path_safety.dart';
import '../manifest/models.dart';

class FdamPaths {
  FdamPaths(this.root);

  final Directory root;

  Directory get assets => Directory(p.join(root.path, 'assets'));
  Directory get databases => Directory(p.join(root.path, 'databases'));
  Directory get staging => Directory(p.join(root.path, 'staging'));
  Directory get temp => Directory(p.join(root.path, 'temp'));
  Directory get metadata => Directory(p.join(root.path, 'metadata'));
  Directory get backups => Directory(p.join(root.path, 'backups'));

  File get manifestCache => File(p.join(metadata.path, 'manifest_cache.json'));
  File get downloadState => File(p.join(metadata.path, 'download_state.json'));
  File get logFile => File(p.join(metadata.path, 'fdam.log'));
  String get databasePath => p.join(metadata.path, 'fdam.db');

  Future<void> ensure() async {
    for (final d in [assets, databases, staging, temp, metadata, backups]) {
      await d.create(recursive: true);
    }
    for (final c in AssetCategory.values) {
      await Directory(p.join(root.path, c.storageDir)).create(recursive: true);
    }
  }

  /// Absolute install path for [item]; throws if the manifest path escapes
  /// the root (validated earlier, checked again here).
  String installPath(AssetItem item) {
    final path = safeJoin(root.path, item.installRelativePath);
    if (path == null) throw ArgumentError('unsafe install path for ${item.id}');
    return path;
  }

  /// Converts an absolute path inside root to the relative form stored in
  /// the database (so the app data folder can move).
  String toRelative(String absolute) => p.relative(absolute, from: root.path);
  String toAbsolute(String relative) => safeJoin(root.path, relative) ?? (throw ArgumentError('unsafe path'));

  String partFile(AssetItem item) =>
      p.join(temp.path, '${item.id}-${item.version}-${item.sha256.substring(0, 12)}.part');

  String stagingDir(AssetItem item) => p.join(staging.path, '${item.id}-${item.version}-${_stamp()}');

  String backupPath(String assetId, String version) => p.join(backups.path, assetId, version);

  static String _stamp() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}

/// Deletes a file or directory if it exists; never throws.
Future<void> deletePath(String path) async {
  try {
    final type = await FileSystemEntity.type(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(path).delete(recursive: true);
      case FileSystemEntityType.file:
      case FileSystemEntityType.link:
        await File(path).delete();
      default:
        break;
    }
  } catch (_) {}
}

Future<bool> pathExists(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.notFound;

/// Total size of a file or directory tree (links are not followed).
Future<int> pathSize(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.file) return File(path).length();
  if (type != FileSystemEntityType.directory) return 0;
  var total = 0;
  await for (final e in Directory(path).list(recursive: true, followLinks: false)) {
    if (e is File) {
      try {
        total += await e.length();
      } catch (_) {}
    }
  }
  return total;
}

/// Writes [contents] to [file] atomically (temp file + rename).
Future<void> writeAtomic(File file, String contents) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(contents, flush: true);
  await tmp.rename(file.path);
}
