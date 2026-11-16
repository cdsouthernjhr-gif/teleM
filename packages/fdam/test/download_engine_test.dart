import 'dart:io';

import 'package:fdam/fdam.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_env.dart';

void main() {
  late TestEnv env;
  late DownloadEngine engine;
  late FdamDatabase db;

  AssetItem itemFor(TestAsset a, {String? path}) => AssetItem.fromJson({
        ...env.assetJson(a),
        if (path != null) 'url': env.server.url(path),
      });

  Future<DownloadEngine> makeEngine({int concurrency = 2}) async {
    final cfg = FdamConfig(
      manifestUrl: env.config.manifestUrl,
      appId: kTestAppId,
      insecureHttpHosts: const {'127.0.0.1'},
      retryBaseDelay: const Duration(milliseconds: 20),
      retryMaxDelay: const Duration(milliseconds: 100),
      maxRetries: 3,
      maxConcurrentDownloads: concurrency,
      receiveTimeout: const Duration(seconds: 5),
    );
    await env.paths.ensure();
    db = await env.db();
    return DownloadEngine(
      config: cfg,
      http: FdamHttp(cfg),
      db: db,
      paths: env.paths,
      network: env.network,
      logger: FdamLogger(echo: false),
      wifiOnly: () => env.prefs.wifiOnly,
    );
  }

  setUp(() async {
    env = await TestEnv.create();
    engine = await makeEngine();
  });
  tearDown(() async {
    await engine.dispose();
    await env.dispose();
  });

  final big = TestAsset('vid', 'vid.mp4', 'video', randomBytes(600 * 1024, seed: 3));

  test('downloads, streams to .part and verifies SHA-256', () async {
    env.publish([big]);
    final updates = <DownloadTask>[];
    engine.updates.listen(updates.add);
    final path = await engine.enqueue(itemFor(big));
    expect(path, endsWith('.part'));
    expect(await File(path).readAsBytes(), big.bytes);
    expect(updates.map((u) => u.status), containsAllInOrder([DownloadStatus.downloading, DownloadStatus.verifying, DownloadStatus.completed]));
    expect(updates.last.downloadedBytes, big.bytes.length);
  });

  test('follows a GitHub-style redirect', () async {
    env.publish([big]);
    env.server.redirects['/gh/vid.mp4'] = '/releases/download/v1.0.0/vid.mp4';
    final path = await engine.enqueue(itemFor(big, path: '/gh/vid.mp4'));
    expect(await File(path).length(), big.bytes.length);
  });

  test('interrupted download resumes with Range + If-Range (ETag)', () async {
    env.publish([big]);
    env.server.interruptAfterBytes = 200 * 1024;
    final path = await engine.enqueue(itemFor(big));
    expect(await File(path).readAsBytes(), big.bytes);
    final gets = env.server.requests.where((r) => r.path.endsWith('vid.mp4')).toList();
    expect(gets.length, 2);
    expect(gets[1].headers['range'], 'bytes=${200 * 1024}-');
    expect(gets[1].headers['if-range'], env.server.etags['/releases/download/v1.0.0/vid.mp4']);
  });

  test('server without Range support restarts from zero correctly', () async {
    env.publish([big]);
    env.server.supportRange = false;
    env.server.interruptAfterBytes = 100 * 1024;
    final path = await engine.enqueue(itemFor(big));
    expect(await File(path).readAsBytes(), big.bytes);
  });

  test('no ETag/Last-Modified validator: partial file is discarded, not trusted', () async {
    env.publish([big]);
    final item = itemFor(big);
    await env.paths.ensure();
    // A stale partial file from somewhere else.
    await File(env.paths.partFile(item)).writeAsBytes(randomBytes(1000, seed: 99));
    final path = await engine.enqueue(item);
    expect(await File(path).readAsBytes(), big.bytes);
    expect(env.server.requests.last.headers['range'], isNull);
  });

  test('wrong content -> CHECKSUM_MISMATCH, .part deleted, retried, then succeeds', () async {
    env.publish([big]);
    env.server.corruptOnce['/releases/download/v1.0.0/vid.mp4'] = randomBytes(big.bytes.length, seed: 7);
    final updates = <DownloadTask>[];
    engine.updates.listen(updates.add);
    final path = await engine.enqueue(itemFor(big));
    expect(await File(path).readAsBytes(), big.bytes);
    expect(updates.any((u) => u.lastError == FdamErrorCode.checksumMismatch), isTrue);
  });

  test('always wrong content fails after maxRetries with CHECKSUM_MISMATCH', () async {
    final a = TestAsset('bad', 'bad.bin', 'data', randomBytes(5000));
    env.publish([a]);
    final item = AssetItem.fromJson({...env.assetJson(a), 'sha256': 'f' * 64});
    await expectLater(engine.enqueue(item),
        throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.checksumMismatch)));
    expect(await File(env.paths.partFile(item)).exists(), isFalse);
    final rec = await db.download('bad');
    expect(rec!.status, DownloadStatus.failed);
    expect(rec.lastError, startsWith('CHECKSUM_MISMATCH'));
    expect(rec.retryCount, 3);
  });

  test('404 (release missing) -> FILE_NOT_FOUND without endless retries', () async {
    final a = TestAsset('miss', 'miss.bin', 'data', randomBytes(10));
    await expectLater(engine.enqueue(itemFor(a)),
        throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.fileNotFound)));
    expect(env.server.count('/releases/download/v1.0.0/miss.bin'), 1);
  });

  test('5xx is retried with backoff', () async {
    env.publish([big]);
    env.server.failNext = 2;
    final path = await engine.enqueue(itemFor(big));
    expect(await File(path).length(), big.bytes.length);
  });

  test('duplicate enqueue returns the same download', () async {
    env.publish([big]);
    final f1 = engine.enqueue(itemFor(big));
    final f2 = engine.enqueue(itemFor(big));
    expect(identical(f1, f2), isTrue);
    await f1;
    expect(env.server.count('/releases/download/v1.0.0/vid.mp4'), 1);
  });

  test('pause keeps the .part file, resume continues with Range', () async {
    env.publish([big]);
    env.server.chunkDelay = const Duration(milliseconds: 15);
    final item = itemFor(big);
    final done = engine.enqueue(item);
    await engine.updates.firstWhere((t) => t.downloadedBytes > 64 * 1024);
    engine.pause(item.id);
    await engine.updates.firstWhere((t) => t.status == DownloadStatus.paused);
    final partLen = await File(env.paths.partFile(item)).length();
    expect(partLen, greaterThan(0));
    expect((await db.download(item.id))!.status, DownloadStatus.paused);
    env.server.chunkDelay = Duration.zero;
    engine.resume(item.id);
    await done;
    final last = env.server.requests.last;
    expect(last.headers['range'], startsWith('bytes='));
  });

  test('cancel deletes the .part file and completes with CANCELLED', () async {
    env.publish([big]);
    env.server.chunkDelay = const Duration(milliseconds: 15);
    final item = itemFor(big);
    final done = engine.enqueue(item);
    await engine.updates.firstWhere((t) => t.downloadedBytes > 32 * 1024);
    engine.cancel(item.id);
    await expectLater(done, throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.cancelled)));
    expect(await File(env.paths.partFile(item)).exists(), isFalse);
    expect(await db.download(item.id), isNull);
  });

  test('priority queue: required before startup before optional (concurrency 1)', () async {
    await engine.dispose();
    engine = await makeEngine(concurrency: 1);
    final o = TestAsset('opt', 'o.bin', 'data', randomBytes(1000, seed: 1));
    final s = TestAsset('start', 's.bin', 'data', randomBytes(1000, seed: 2), startup: true);
    final r = TestAsset('req', 'r.bin', 'data', randomBytes(1000, seed: 3), required: true);
    final blocker = TestAsset('first', 'f.bin', 'data', randomBytes(64 * 1024, seed: 4), required: true);
    env.publish([o, s, r, blocker]);
    env.server.chunkDelay = const Duration(milliseconds: 20);
    final futures = [
      engine.enqueue(itemFor(blocker)), // occupies the only slot
      engine.enqueue(itemFor(o)),
      engine.enqueue(itemFor(s)),
      engine.enqueue(itemFor(r)),
    ];
    await Future.wait(futures);
    final order = env.server.requests.map((q) => q.path.split('/').last).toList();
    expect(order, ['f.bin', 'r.bin', 's.bin', 'o.bin']);
  });

  test('waits for network, then continues when the connection returns', () async {
    env.publish([big]);
    env.network.set(NetworkKind.none, false);
    final item = itemFor(big);
    final done = engine.enqueue(item);
    await engine.updates.firstWhere((t) => t.status == DownloadStatus.waitingForNetwork);
    expect(env.server.requests, isEmpty);
    env.network.set(NetworkKind.wifi, true);
    await done;
  });

  test('Wi-Fi only mode does not use mobile data', () async {
    env.publish([big]);
    env.prefs.wifiOnly = true;
    env.network.set(NetworkKind.mobile, true);
    final done = engine.enqueue(itemFor(big));
    await engine.updates.firstWhere((t) => t.status == DownloadStatus.waitingForNetwork);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(env.server.requests, isEmpty);
    env.network.set(NetworkKind.wifi, true);
    await done;
  });

  test('Content-Length different from the manifest is rejected', () async {
    final a = TestAsset('len', 'len.bin', 'data', randomBytes(4000));
    env.publish([a]);
    final item = AssetItem.fromJson({...env.assetJson(a), 'sizeBytes': 3000});
    await expectLater(engine.enqueue(item), throwsA(isA<FdamException>()));
  });

  test('timeout while the server stalls is a retryable interruption', () async {
    // Stall server: accepts and never answers.
    final stall = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    stall.listen(sockets.add);
    final cfg = FdamConfig(
      manifestUrl: env.config.manifestUrl,
      appId: kTestAppId,
      insecureHttpHosts: const {'127.0.0.1'},
      receiveTimeout: const Duration(milliseconds: 300),
      connectTimeout: const Duration(milliseconds: 300),
      retryBaseDelay: const Duration(milliseconds: 10),
      maxRetries: 1,
    );
    final e2 = DownloadEngine(
        config: cfg, http: FdamHttp(cfg), db: db, paths: env.paths, network: env.network, logger: FdamLogger(echo: false));
    final a = TestAsset('stall', 'stall.bin', 'data', randomBytes(100));
    final item = AssetItem.fromJson({...env.assetJson(a), 'url': 'http://127.0.0.1:${stall.port}/stall.bin'});
    await expectLater(e2.enqueue(item).timeout(const Duration(seconds: 20)), throwsA(isA<FdamException>()));
    await e2.dispose();
    for (final s in sockets) {
      s.destroy();
    }
    await stall.close();
  });
}
