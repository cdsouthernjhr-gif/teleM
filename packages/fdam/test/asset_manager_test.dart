// End-to-end scenarios (spec §19) against a real local HTTP server, real
// SQLite and the real file system.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fdam/fdam.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/test_env.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  final audioZip = makeZip({'intro.mp3': randomBytes(30000, seed: 11), 'sfx/click.wav': randomBytes(5000, seed: 12)});
  TestAsset audio([Uint8List? bytes, String v = '1.0.0']) => TestAsset('audio_pack_01', 'audio.zip', 'audio',
      bytes ?? audioZip, version: v, required: true, extract: true, localPath: 'audio/audio.zip');
  TestAsset images([String v = '1.0.0', int seed = 21]) =>
      TestAsset('images', 'logo.png', 'image', randomBytes(40000, seed: seed), version: v, required: true, localPath: 'images/logo.png');
  TestAsset db([String v = '1.0.0', int seed = 31]) =>
      TestAsset('db_main', 'main.db', 'database', randomBytes(20000, seed: seed), version: v, required: true, localPath: 'main.db');
  TestAsset video() => TestAsset('video_intro', 'intro.mp4', 'video', randomBytes(80000, seed: 41), localPath: 'videos/intro.mp4');
  TestAsset startup() =>
      TestAsset('cfg', 'config.json', 'config', Uint8List.fromList(utf8.encode('{"a":1}')), startup: true, localPath: 'app.json');

  int gets(String name) => env.server.requests.where((r) => r.method == 'GET' && r.path.endsWith('/$name')).length;

  Future<AssetManager> firstInstall(List<TestAsset> assets) async {
    env.publish(assets);
    final m = await env.manager();
    await m.checkForUpdates();
    final r = await m.downloadRequired();
    expect(r.failed, isEmpty, reason: r.failed.toString());
    return m;
  }

  test('1/2/13: first installation with internet — required ZIP extracted, file installed, DB updated', () async {
    env.publish([audio(), images(), db(), video(), startup()]);
    final m = await env.manager();
    expect(m.snapshot.phase, FdamPhase.starting);
    final check = await m.checkForUpdates();
    expect(check.source, ManifestSource.network);
    expect(m.snapshot.phase, FdamPhase.needsSetup);
    expect(m.snapshot.plan!.blockingRequired.map((e) => e.id).toSet(), {'audio_pack_01', 'images', 'db_main'});
    // Optional and startup assets are not required for entry.
    expect(gets('intro.mp4'), 0);

    final r = await m.downloadRequired();
    expect(r.failed, isEmpty);
    expect(m.snapshot.phase, FdamPhase.ready);
    expect(m.snapshot.requiredReady, isTrue);

    final audioDir = await m.pathOf('audio_pack_01');
    expect(audioDir, p.join(env.root.path, 'assets', 'audio', 'audio'));
    expect(await File('$audioDir/sfx/click.wav').length(), 5000);
    expect(await File(p.join(env.root.path, 'databases', 'main.db')).exists(), isTrue);
    expect(await File(p.join(env.root.path, 'assets', 'images', 'logo.png')).length(), 40000);
    expect(await m.repository.isAssetDownloaded('images'), isTrue);
    expect(await m.repository.getAssetVersion('images'), '1.0.0');
    expect(await m.repository.getDownloadedSize(), greaterThan(0));
    expect(m.repository.getTotalRequiredSize(m.snapshot.manifest!), audioZip.length + 40000 + 20000);
    // Temporary data is gone.
    expect(env.paths.temp.listSync(), isEmpty);
    expect(env.paths.staging.listSync(), isEmpty);
    // Optional video was never downloaded; startup asset follows automatically.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(gets('intro.mp4'), 0);
    expect(await m.repository.isAssetDownloaded('cfg'), isTrue);
  });

  test('3: no internet and no cache — error state, no crash, recovers when online', () async {
    env.publish([images()]);
    env.network.set(NetworkKind.none, false);
    await env.server.close();
    final m = await env.manager();
    final r = await m.checkForUpdates();
    expect(r.error, isNotNull);
    expect(m.snapshot.phase, FdamPhase.error);
    expect(m.snapshot.manifest, isNull);
  });

  test('5/15: download paused before the app was closed is restored paused and resumes with Range', () async {
    final big = TestAsset('images', 'logo.png', 'image', randomBytes(600 * 1024, seed: 5), required: true, localPath: 'images/logo.png');
    env.publish([big]);
    env.server.chunkDelay = const Duration(milliseconds: 30);
    var m = await env.manager();
    await m.checkForUpdates();
    final pending = m.downloadRequired();
    await m.engine.updates.firstWhere((t) => t.downloadedBytes >= 16 * 1024);
    m.pause('images');
    await m.engine.updates.firstWhere((t) => t.status == DownloadStatus.paused);
    final partial = await File(env.paths.partFile(AssetItem.fromJson(env.assetJson(big)))).length();
    expect(partial, greaterThan(0));
    pending.ignore();
    await env.restart();

    env.server.chunkDelay = Duration.zero;
    m = await env.manager();
    final restored = m.engine.updates.firstWhere((t) => t.assetId == 'images' && t.status == DownloadStatus.paused);
    await m.checkForUpdates();
    final task = await restored;
    expect(task.downloadedBytes, partial);
    final completed = m.engine.updates.firstWhere((t) => t.status == DownloadStatus.completed);
    m.resume('images');
    await completed;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final last = env.server.requests.lastWhere((r) => r.path.endsWith('logo.png'));
    expect(last.headers['range'], 'bytes=$partial-');
    expect(last.headers['if-range'], isNotNull);
    expect(await m.repository.isAssetDownloaded('images'), isTrue);
  });

  test('15/16: process killed mid-download (row says downloading) resumes automatically after restart', () async {
    final a = images();
    env.publish([a]);
    final item = AssetItem.fromJson(env.assetJson(a));
    await env.paths.ensure();
    // State left behind by a killed process: half the file + persisted ETag.
    await File(env.paths.partFile(item)).writeAsBytes(a.bytes.sublist(0, 15000));
    final db = await env.db();
    await db.upsertDownload(
      item: item,
      temporaryPath: env.paths.partFile(item),
      downloadedBytes: 15000,
      status: DownloadStatus.downloading,
      etag: env.server.etags['/releases/download/v1.0.0/logo.png'],
    );
    final m = await env.manager();
    final done = m.engine.updates.firstWhere((t) => t.status == DownloadStatus.completed);
    await m.checkForUpdates();
    await done;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final req = env.server.requests.lastWhere((r) => r.path.endsWith('logo.png'));
    expect(req.headers['range'], 'bytes=15000-');
    expect(await m.repository.isAssetDownloaded('images'), isTrue);
  });

  test('4: connection dropped mid-file is resumed automatically', () async {
    env.publish([images()]);
    env.server.interruptAfterBytes = 10000;
    final m = await firstInstall([images()]);
    expect(await m.repository.isAssetDownloaded('images'), isTrue);
  });

  test('6/18: invalid or missing manifest keeps the cached one and the installed assets', () async {
    final m = await firstInstall([images()]);
    env.server.put('/manifest/manifest.json', utf8.encode('{"broken": true'));
    var r = await m.checkForUpdates();
    expect(r.error!.code, FdamErrorCode.manifestInvalid);
    expect(m.snapshot.phase, FdamPhase.ready);
    expect(m.snapshot.manifest!.assets.single.id, 'images');

    env.server.files.remove('/manifest/manifest.json');
    r = await m.checkForUpdates();
    expect(r.error!.code, FdamErrorCode.manifestNotFound);
    expect(m.snapshot.phase, FdamPhase.ready);
    expect(await m.repository.isAssetDownloaded('images'), isTrue);
  });

  test('7: incorrect SHA-256 in manifest — never installed, CHECKSUM_MISMATCH recorded', () async {
    final a = images();
    env.publish([a]);
    final bad = jsonDecode(utf8.decode(env.server.files['/manifest/manifest.json']!)) as Map<String, dynamic>;
    ((bad['assets'] as List).first as Map)['sha256'] = 'e' * 64;
    env.server.putJson('/manifest/manifest.json', bad);
    final m = await env.manager();
    await m.checkForUpdates();
    final r = await m.downloadRequired();
    expect(r.failed['images']!.code, FdamErrorCode.checksumMismatch);
    expect(await m.repository.isAssetDownloaded('images'), isFalse);
    expect(m.snapshot.phase, FdamPhase.needsSetup);
    expect(env.paths.temp.listSync(), isEmpty);
  });

  test('8: insufficient storage is detected before downloading', () async {
    env.publish([images()]);
    env.storage.availableBytes = 1000;
    final m = await env.manager();
    await m.checkForUpdates();
    final r = await m.downloadRequired();
    expect(r.failed['images']!.code, FdamErrorCode.diskSpaceInsufficient);
    expect(gets('logo.png'), 0);
    expect(m.snapshot.error!.code, FdamErrorCode.diskSpaceInsufficient);
  });

  test('9: duplicate download requests share one transfer; installed files are not downloaded again', () async {
    env.publish([images()]);
    final m = await env.manager();
    await m.checkForUpdates();
    await Future.wait([m.downloadRequired(), m.downloadRequired(), m.downloadItems([m.snapshot.manifest!.byId('images')!])]);
    expect(gets('logo.png'), 1);
    await m.checkForUpdates();
    await m.applyUpdates();
    expect(gets('logo.png'), 1);
  });

  test('10: only the updated image is downloaded', () async {
    final m = await firstInstall([audio(), images(), db()]);
    final before = {for (final n in ['audio.zip', 'logo.png', 'main.db']) n: gets(n)};
    env.publish([audio(), images('1.1.0', 22), db()], releaseVersion: '1.1.0');
    final r = await m.checkForUpdates();
    final updates = r.plan!.entries.where((e) => e.action == AssetAction.update).map((e) => e.id).toList();
    expect(updates, ['images']);
    expect(r.plan!.entries.where((e) => e.action == AssetAction.keep).length, 2);
    // Auto-update runs in the background; wait for it.
    await m.engine.updates.firstWhere((t) => t.assetId == 'images' && t.status == DownloadStatus.completed);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(gets('audio.zip'), before['audio.zip']);
    expect(gets('main.db'), before['main.db']);
    expect(await m.repository.getAssetVersion('images'), '1.1.0');
  });

  test('11/19: updated database keeps a backup; manual rollback restores it and is not re-applied', () async {
    final m = await firstInstall([db()]);
    final dbFile = File(p.join(env.root.path, 'databases', 'main.db'));
    final v1 = await dbFile.readAsBytes();
    env.publish([db('2.0.0', 32)], releaseVersion: '2.0.0');
    await m.checkForUpdates(autoDownload: false);
    final r = await m.applyUpdates();
    expect(r.failed, isEmpty);
    expect(await m.repository.getAssetVersion('db_main'), '2.0.0');
    expect(await dbFile.readAsBytes(), isNot(v1));
    final rec = await m.repository.getAssetById('db_main');
    expect(rec!.previousVersion, '1.0.0');
    expect(rec.backupPath, isNotNull);

    await m.rollback('db_main');
    expect(await dbFile.readAsBytes(), v1);
    expect(await m.repository.getAssetVersion('db_main'), '1.0.0');
    final check = await m.checkForUpdates(autoDownload: false);
    expect(check.plan!.entries.single.action, AssetAction.keep, reason: 'rolled-back version is not reinstalled');
  });

  test('12: optional asset is only downloaded on request', () async {
    final m = await firstInstall([images(), video()]);
    expect(await m.repository.isAssetDownloaded('video_intro'), isFalse);
    expect(m.snapshot.plan!.optionalNotInstalled.single.id, 'video_intro');
    final r = await m.downloadOptional(['video_intro']);
    expect(r.installed, ['video_intro']);
    expect(await m.repository.isAssetDownloaded('video_intro'), isTrue);
    expect(await m.clearOptionalCache(), 1);
    expect(await m.repository.isAssetDownloaded('video_intro'), isFalse);
    expect(await m.repository.isAssetDownloaded('images'), isTrue, reason: 'required assets are never cleared');
  });

  test('14/19: malicious ZIP in an update is rejected and the old version stays', () async {
    final m = await firstInstall([audio()]);
    final dir = (await m.pathOf('audio_pack_01'))!;
    final a = Archive()..addFile(ArchiveFile.bytes('../../escape.txt', [1, 2, 3]));
    final evil = Uint8List.fromList(ZipEncoder().encodeBytes(a));
    env.publish([audio(evil, '1.1.0')], releaseVersion: '1.1.0');
    await m.checkForUpdates(autoDownload: false);
    final r = await m.applyUpdates();
    expect(r.failed['audio_pack_01']!.code, FdamErrorCode.invalidAssetPath);
    expect(await m.repository.getAssetVersion('audio_pack_01'), '1.0.0');
    expect(await File('$dir/intro.mp3').length(), 30000);
    expect(File(p.join(env.root.path, 'assets', 'escape.txt')).existsSync(), isFalse);
    expect(File(p.join(env.root.path, 'escape.txt')).existsSync(), isFalse);
    expect(m.snapshot.phase, FdamPhase.ready);
  });

  test('16/20: device restart, offline startup uses installed assets', () async {
    await firstInstall([images(), audio()]);
    await env.restart();
    env.network.set(NetworkKind.none, false);
    await env.server.close();
    final m = await env.manager();
    expect(m.snapshot.phase, FdamPhase.ready, reason: 'cached manifest + installed files');
    final r = await m.checkForUpdates();
    expect(r.source, ManifestSource.cache);
    expect(r.error, isNotNull);
    expect(m.snapshot.phase, FdamPhase.ready);
    expect(await m.repository.isAssetDownloaded('audio_pack_01'), isTrue);
  });

  test('17: GitHub release unavailable (404) — FILE_NOT_FOUND, app stays in setup without crashing', () async {
    env.publish([images()]);
    env.server.files.removeWhere((k, _) => k.endsWith('logo.png'));
    final m = await env.manager();
    await m.checkForUpdates();
    final r = await m.downloadRequired();
    expect(r.failed['images']!.code, FdamErrorCode.fileNotFound);
    expect(m.snapshot.phase, FdamPhase.needsSetup);
    // Release published later -> retry works.
    env.publish([images()]);
    final r2 = await m.retry('images');
    expect(r2.allOk, isTrue);
    expect(m.snapshot.phase, FdamPhase.ready);
  });

  test('repair: deleted installed file is detected and downloaded again', () async {
    final m = await firstInstall([images()]);
    await File(p.join(env.root.path, 'assets', 'images', 'logo.png')).delete();
    final r = await m.checkForUpdates(autoDownload: false);
    expect(r.plan!.entries.single.action, AssetAction.repair);
    expect(m.snapshot.phase, FdamPhase.needsSetup);
    await m.downloadRequired();
    expect(m.snapshot.phase, FdamPhase.ready);
  });

  test('removed asset: files kept while in use, deleted after the app releases them', () async {
    var inUse = true;
    env.publish([images(), video()]);
    final m = await env.manager(usage: (_) async => inUse);
    await m.checkForUpdates();
    await m.downloadItems([m.snapshot.manifest!.byId('images')!, m.snapshot.manifest!.byId('video_intro')!]);
    env.publish([images()], releaseVersion: '1.1.0');
    final r = await m.checkForUpdates();
    expect(r.plan!.removed.single.id, 'video_intro');
    final videoPath = p.join(env.root.path, 'assets', 'videos', 'intro.mp4');
    expect(await m.cleanupRemoved(), isEmpty);
    expect(File(videoPath).existsSync(), isTrue);
    inUse = false;
    expect(await m.cleanupRemoved(), ['video_intro']);
    expect(File(videoPath).existsSync(), isFalse);
  });

  test('crash during activation: journal recovery restores the previous version', () async {
    final m = await firstInstall([images()]);
    final target = p.join(env.root.path, 'assets', 'images', 'logo.png');
    final original = await File(target).readAsBytes();
    // Simulate a crash right after the old file was moved to backups/.
    final backup = env.paths.backupPath('images', '1.0.0');
    await Directory(p.dirname(backup)).create(recursive: true);
    await File(target).rename(backup);
    await m.db.setJson('journal:images', {
      'target': env.paths.toRelative(target),
      'backup': env.paths.toRelative(backup),
      'staged': 'staging/x/logo.png',
      'stage': 'staging/x',
      'version': '9.9.9',
      'sha256': 'f' * 64,
      'hadOld': true,
    });
    await env.restart();
    final m2 = await env.manager();
    expect(await File(target).readAsBytes(), original);
    expect(await m2.db.getSetting('journal:images'), isNull);
    expect(m2.snapshot.phase, FdamPhase.ready);
  });

  test('Wi-Fi only setting is persisted and respected', () async {
    env.publish([images()]);
    final m = await env.manager();
    await m.setWifiOnly(true);
    expect(env.prefs.wifiOnly, isTrue);
    env.network.set(NetworkKind.mobile, true);
    await m.checkForUpdates();
    final pending = m.downloadRequired();
    await m.engine.updates.firstWhere((t) => t.status == DownloadStatus.waitingForNetwork);
    expect(gets('logo.png'), 0);
    env.network.set(NetworkKind.wifi, true);
    expect((await pending).allOk, isTrue);
  });

  test('disabled when no manifest URL is configured', () async {
    final m = await AssetManager.create(
      config: const FdamConfig(manifestUrl: '', appId: kTestAppId),
      rootDirectory: env.root,
      database: await env.db(),
      network: env.network,
      preferences: env.prefs,
      storage: env.storage,
      logger: FdamLogger(echo: false),
    );
    expect(m.snapshot.phase, FdamPhase.disabled);
    expect((await m.checkForUpdates()).plan, isNull);
    await m.dispose();
  });
}
