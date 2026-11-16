// The manifest produced by asset_repo_template/tools/generate_manifest.py
// must be accepted by the Dart validator and install end-to-end.

import 'dart:convert';
import 'dart:io';

import 'package:fdam/fdam.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/test_server.dart';

const _template = '../../asset_repo_template';

void main() {
  final manifestFile = File('$_template/manifest/manifest.json');

  test('sample manifest from the Python generator passes the Dart validator', () {
    final json = jsonDecode(manifestFile.readAsStringSync());
    const config = FdamConfig(
      manifestUrl: 'https://raw.githubusercontent.com/USERNAME/MyFlutterApp-Assets/main/manifest/manifest.json',
      appId: 'com.example.myapp',
      allowedUrlPrefixes: ['https://github.com/USERNAME/MyFlutterApp-Assets/releases/download/'],
    );
    final r = ManifestValidator(config).validate(json);
    expect(r.errors, isEmpty);
    expect(r.manifest!.assets.length, 5);
    for (final a in r.manifest!.assets) {
      expect(a.sha256, isNot(contains('REAL')));
    }
  });

  test('sample release installs end-to-end (files served locally, hashes unchanged)', () async {
    sqfliteFfiInit();
    final server = await TestServer.start();
    final root = await Directory.systemTemp.createTemp('fdam_tpl_');
    try {
      final m = jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      for (final a in (m['assets'] as List).cast<Map<String, dynamic>>()) {
        final name = a['name'] as String;
        server.put('/dl/$name', File('$_template/examples/release-assets/$name').readAsBytesSync());
        a['url'] = server.url('/dl/$name'); // only the host changes
      }
      server.putJson('/manifest.json', m);
      final config = FdamConfig(
        manifestUrl: server.url('/manifest.json'),
        appId: 'com.example.myapp',
        insecureHttpHosts: const {'127.0.0.1'},
        storageSafetyMarginBytes: 0,
      );
      final mgr = await AssetManager.create(
        config: config,
        rootDirectory: root,
        database: await FdamDatabase.open(p.join(root.path, 'fdam.db'), factory: databaseFactoryFfi),
        network: ManualNetworkMonitor(),
        preferences: MemoryFdamPreferences(),
        storage: FixedStorageInfo(1 << 30),
        logger: FdamLogger(echo: false),
      );
      await mgr.checkForUpdates();
      final r = await mgr.downloadRequired();
      expect(r.failed, isEmpty);
      expect(mgr.snapshot.phase, FdamPhase.ready);
      expect(await File(p.join(root.path, 'assets/audio/audio/click.wav')).exists(), isTrue);
      expect(await File(p.join(root.path, 'assets/images/images/icons/blue.png')).exists(), isTrue);
      expect(await File(p.join(root.path, 'databases/main/main.db')).exists(), isTrue);
      final dbFile = await mgr.fileIn('database_main', 'main.db');
      expect(dbFile, isNotNull);
      expect(await mgr.fileIn('database_main', '../escape'), isNull);
      // Optional videos were not downloaded.
      expect(await mgr.repository.isAssetDownloaded('videos_pack_01'), isFalse);
      await mgr.dispose();
      await mgr.db.close();
    } finally {
      await server.close();
      await root.delete(recursive: true);
    }
  });
}
