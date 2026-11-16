import 'dart:io';

import 'package:fdam/fdam.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

AssetItem item(String id, {String version = '1.0.0', bool required = false}) => AssetItem(
      id: id,
      name: '$id.bin',
      category: AssetCategory.data,
      version: version,
      url: 'https://github.com/u/r/releases/download/v$version/$id.bin',
      localPath: '$id.bin',
      sizeBytes: 10,
      sha256: 'b' * 64,
      required: required,
    );

void main() {
  late Directory tmp;
  setUpAll(sqfliteFfiInit);
  setUp(() async => tmp = await Directory.systemTemp.createTemp('fdam_db_'));
  tearDown(() async => tmp.delete(recursive: true));

  test('fresh database has spec tables plus v2 columns', () async {
    final db = await FdamDatabase.open('${tmp.path}/a.db', factory: databaseFactoryFfi);
    final cols = (await db.db.rawQuery('PRAGMA table_info(assets)')).map((r) => r['name']).toSet();
    expect(cols, containsAll(['id', 'name', 'category', 'version', 'local_path', 'size_bytes', 'sha256', 'status',
        'downloaded_at', 'updated_at', 'previous_version', 'backup_path']));
    final dl = (await db.db.rawQuery('PRAGMA table_info(downloads)')).map((r) => r['name']).toSet();
    expect(dl, containsAll(['id', 'asset_id', 'download_url', 'temporary_path', 'downloaded_bytes', 'total_bytes',
        'status', 'retry_count', 'last_error', 'created_at', 'updated_at', 'etag']));
    expect(await db.db.getVersion(), kFdamDbVersion);
    await db.close();
  });

  test('migrates a v1 database to the current version keeping data', () async {
    final path = '${tmp.path}/old.db';
    final v1 = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(
            version: 1,
            onCreate: (d, _) async {
              for (final s in kFdamMigrations[0]) {
                await d.execute(s);
              }
            }));
    await v1.insert('assets', {
      'id': 'old',
      'name': 'old.bin',
      'category': 'data',
      'version': '0.9.0',
      'local_path': 'assets/data/old.bin',
      'size_bytes': 3,
      'sha256': 'c' * 64,
      'status': 'installed',
    });
    await v1.close();
    final db = await FdamDatabase.open(path, factory: databaseFactoryFfi);
    final r = await db.asset('old');
    expect(r!.version, '0.9.0');
    expect(r.priority, 3);
    expect(r.inManifest, isTrue);
    await db.close();
  });

  test('records, downloads, settings and manifest sync survive reopen', () async {
    final path = '${tmp.path}/b.db';
    var db = await FdamDatabase.open(path, factory: databaseFactoryFfi);
    await db.recordInstalled(item('keep', required: true), localPath: 'assets/data/keep.bin', sizeOnDisk: 10);
    await db.recordInstalled(item('gone'), localPath: 'assets/data/gone.bin', sizeOnDisk: 10);
    await db.upsertDownload(
        item: item('dl'), temporaryPath: '/t/dl.part', downloadedBytes: 4, status: DownloadStatus.downloading, etag: '"e"');
    await db.setSetting('k', 'v');
    await db.close();

    db = await FdamDatabase.open(path, factory: databaseFactoryFfi);
    expect((await db.download('dl'))!.downloadedBytes, 4);
    expect((await db.download('dl'))!.etag, '"e"');
    expect(await db.getSetting('k'), 'v');

    final manifest = AssetManifest(
        schemaVersion: 1,
        appId: 'x',
        releaseVersion: '1.0.0',
        minimumManagerVersion: '1.0.0',
        generatedAt: DateTime.utc(2026),
        assets: [item('keep', required: true)]);
    await db.syncManifestFlags(manifest);
    final gone = await db.asset('gone');
    expect(gone!.status, LocalAssetStatus.removed);
    expect(gone.inManifest, isFalse);
    expect((await db.asset('keep'))!.status, LocalAssetStatus.installed);
    expect(await db.download('dl'), isNull, reason: 'download rows for assets not in manifest are dropped');
    await db.close();
  });
}
