// Test environment: temp FDAM root, real SQLite (ffi), local server.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fdam/fdam.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_server.dart';

const String kTestAppId = 'com.example.fdamtest';

Uint8List randomBytes(int n, {int seed = 1}) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

String sha(List<int> b) => sha256.convert(b).toString();

Uint8List makeZip(Map<String, List<int>> entries, {int level = 6}) {
  final a = Archive();
  entries.forEach((name, data) => a.addFile(ArchiveFile.bytes(name, data)));
  return Uint8List.fromList(ZipEncoder().encodeBytes(a, level: level));
}

class TestAsset {
  TestAsset(this.id, this.name, this.category, this.bytes,
      {this.version = '1.0.0', this.required = false, this.startup = false, this.extract = false, String? localPath})
      : localPath = localPath ?? '${category}s/$name';
  final String id;
  final String name;
  final String category;
  final Uint8List bytes;
  final String version;
  final bool required;
  final bool startup;
  final bool extract;
  final String localPath;
}

class TestEnv {
  TestEnv._(this.root, this.server, this.config);

  final Directory root;
  final TestServer server;
  final FdamConfig config;
  final ManualNetworkMonitor network = ManualNetworkMonitor();
  final FixedStorageInfo storage = FixedStorageInfo(10 * 1024 * 1024 * 1024);
  final MemoryFdamPreferences prefs = MemoryFdamPreferences();
  FdamDatabase? _db;
  final List<AssetManager> _managers = [];
  String release = '1.0.0';

  static Future<TestEnv> create({FdamConfig Function(String manifestUrl)? configure}) async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('fdam_test_');
    final server = await TestServer.start();
    final manifestUrl = server.url('/manifest/manifest.json');
    final config = configure?.call(manifestUrl) ??
        FdamConfig(
          manifestUrl: manifestUrl,
          appId: kTestAppId,
          insecureHttpHosts: const {'127.0.0.1'},
          retryBaseDelay: const Duration(milliseconds: 20),
          retryMaxDelay: const Duration(milliseconds: 100),
          maxRetries: 3,
          storageSafetyMarginBytes: 0,
          receiveTimeout: const Duration(seconds: 5),
        );
    return TestEnv._(dir, server, config);
  }

  FdamPaths get paths => FdamPaths(root);

  Future<FdamDatabase> db() async =>
      _db ??= await FdamDatabase.open('${root.path}/metadata/fdam.db', factory: databaseFactoryFfi);

  /// Simulates an app restart: drops the DB handle so the next manager
  /// opens it again from disk.
  Future<void> restart() async {
    for (final m in _managers) {
      await m.dispose();
    }
    _managers.clear();
    await _db?.close();
    _db = null;
  }

  Future<AssetManager> manager({AssetUsageChecker? usage, int? maxConcurrent}) async {
    await Directory('${root.path}/metadata').create(recursive: true);
    final m = await AssetManager.create(
      config: config,
      rootDirectory: root,
      database: await db(),
      network: network,
      preferences: prefs,
      storage: storage,
      logger: FdamLogger(echo: Platform.environment['FDAM_ECHO'] == '1'),
      usageChecker: usage,
    );
    _managers.add(m);
    return m;
  }

  Map<String, dynamic> assetJson(TestAsset a) => {
        'id': a.id,
        'name': a.name,
        'category': a.category,
        'version': a.version,
        'url': server.url('/releases/download/v${a.version}/${a.name}'),
        'localPath': a.localPath,
        'sizeBytes': a.bytes.length,
        'sha256': sha(a.bytes),
        'required': a.required,
        'downloadOnStartup': a.startup,
        'extract': a.extract,
      };

  /// Publishes [assets] (files + manifest) on the local server.
  void publish(List<TestAsset> assets, {String? releaseVersion, Map<String, dynamic>? override}) {
    if (releaseVersion != null) release = releaseVersion;
    for (final a in assets) {
      server.put('/releases/download/v${a.version}/${a.name}', a.bytes);
    }
    server.putJson('/manifest/manifest.json', {
      'schemaVersion': 1,
      'appId': kTestAppId,
      'releaseVersion': release,
      'minimumManagerVersion': '1.0.0',
      'generatedAt': '2026-11-14T10:00:00Z',
      'assets': [for (final a in assets) assetJson(a)],
      ...?override,
    });
  }

  Future<void> dispose() async {
    await restart();
    await server.close();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  }
}

String prettyJson(Object o) => const JsonEncoder.withIndent('  ').convert(o);
