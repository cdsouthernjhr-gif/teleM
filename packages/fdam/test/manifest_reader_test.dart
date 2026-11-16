import 'dart:io';

import 'package:fdam/fdam.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_env.dart';

void main() {
  late TestEnv env;
  late ManifestReader reader;

  setUp(() async {
    env = await TestEnv.create();
    await env.paths.ensure();
    reader = ManifestReader(
      config: env.config,
      http: FdamHttp(env.config, logger: FdamLogger(echo: false)),
      cacheFile: env.paths.manifestCache,
      logger: FdamLogger(echo: false),
    );
  });
  tearDown(() => env.dispose());

  final a = TestAsset('img', 'img.png', 'image', randomBytes(1000));

  test('fetches, validates and caches; then uses ETag (304)', () async {
    env.publish([a]);
    final r1 = await reader.fetch();
    expect(r1.source, ManifestSource.network);
    expect(r1.manifest.assets.single.id, 'img');
    expect(await env.paths.manifestCache.exists(), isTrue);

    final r2 = await reader.fetch();
    expect(r2.source, ManifestSource.notModified);
    final last = env.server.requests.last;
    expect(last.headers['if-none-match'], isNotNull);
  });

  test('offline: falls back to the cache; without cache it throws', () async {
    env.publish([a]);
    await reader.fetch();
    await env.server.close();
    final r = await reader.fetch();
    expect(r.source, ManifestSource.cache);
    expect(r.isOffline, isTrue);
    expect(r.networkError!.code, anyOf(FdamErrorCode.networkUnavailable, FdamErrorCode.downloadInterrupted));

    await env.paths.manifestCache.delete();
    await expectLater(reader.fetch(), throwsA(isA<FdamException>()));
  });

  test('404 -> MANIFEST_NOT_FOUND; invalid JSON / schema -> MANIFEST_INVALID, cache kept', () async {
    await expectLater(reader.fetch(),
        throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.manifestNotFound)));

    env.publish([a]);
    await reader.fetch();
    env.server.put('/manifest/manifest.json', 'not json'.codeUnits);
    await expectLater(reader.fetch(),
        throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.manifestInvalid)));
    env.server.putJson('/manifest/manifest.json', {'schemaVersion': 1});
    await expectLater(reader.fetch(),
        throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.manifestInvalid)));
    // Previous valid manifest still available.
    expect((await reader.readCache())!.manifest.assets.single.id, 'img');
  });

  test('a new release is detected; an older release is refused', () async {
    env.publish([a], releaseVersion: '1.0.0');
    await reader.fetch();
    env.publish([a], releaseVersion: '1.1.0');
    final r = await reader.fetch();
    expect(r.isNewRelease, isTrue);
    env.publish([a], releaseVersion: '1.0.5');
    await expectLater(reader.fetch(),
        throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.versionConflict)));
  });

  test('redirect to a host that is not allowed is refused', () async {
    env.server.redirects['/manifest/manifest.json'] = 'https://evil.example.com/manifest.json';
    await expectLater(reader.fetch(), throwsA(isA<FdamException>()));
  });

  test('manifest larger than the limit is refused', () async {
    final small = FdamConfig(
      manifestUrl: env.config.manifestUrl,
      appId: kTestAppId,
      insecureHttpHosts: const {'127.0.0.1'},
      maxManifestBytes: 100,
    );
    env.publish([a]);
    final r = ManifestReader(config: small, http: FdamHttp(small), cacheFile: File('${env.root.path}/c.json'));
    await expectLater(r.fetch(), throwsA(isA<FdamException>()));
  });
}
