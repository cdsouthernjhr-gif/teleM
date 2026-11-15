import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_asean_tv/data/database_repository.dart';
import 'package:my_asean_tv/data/models.dart';
import 'package:my_asean_tv/data/schema_validator.dart';

import 'helpers.dart';

DatabaseRepository repoWith(Map<String, Map<String, dynamic>> bundled, http.Client client, CacheStore cache,
        {int appBuild = 1}) =>
    DatabaseRepository(
      client: client,
      cache: cache,
      readAsset: (p) async => jsonEncode(bundled[p.split('/').last]),
      baseUrl: 'https://raw.githubusercontent.com/o/r/main/database/',
      appBuild: appBuild,
    );

MockClient serve(Map<String, Map<String, dynamic>> remote, {Set<String> fail = const {}, List<String>? log}) =>
    MockClient((req) async {
      final f = req.url.pathSegments.last;
      log?.add(f);
      if (fail.contains(f)) return http.Response('boom', 500);
      final doc = remote[f];
      return doc == null ? http.Response('nf', 404) : http.Response(jsonEncode(doc), 200);
    });

/// Version of the database shipped in the repo; update tests use v0 + n.
final int v0 = realDatabase()['app_config.json']!['database_version'] as int;

void main() {
  group('Shipped database', () {
    final db = realDatabase();

    test('passes schema validation', () {
      final r = SchemaValidator.validate(db);
      expect(r.errors, isEmpty, reason: r.toString());
    });

    test('has the four countries with all target channels and unique ids', () {
      final b = DatabaseBundle.fromRaw(db);
      expect(b.countries.map((c) => c.code), ['MY', 'ID', 'SG', 'BN']);
      expect(b.channelsFor('MY').length, 11);
      expect(b.channelsFor('ID').length, 15);
      expect(b.channelsFor('SG').length, 6);
      expect(b.channelsFor('BN').length, 4);
      final ids = b.channels.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('no channel claims ONLINE without a tested stream', () {
      final b = DatabaseBundle.fromRaw(db);
      for (final c in b.channels) {
        if (c.availability == StreamStatus.online) {
          expect(c.lastChecked, isNotNull, reason: c.id);
          expect(c.hasDirectStream, isTrue, reason: c.id);
        }
      }
    });

    test('every channel has an official platform URL separate from stream URL', () {
      final b = DatabaseBundle.fromRaw(db);
      for (final c in b.channels) {
        expect(c.officialUrl, startsWith('https://'), reason: c.id);
        expect(c.officialUrl == c.streamUrl, isFalse, reason: c.id);
      }
    });

    test('every category filter works for every country', () {
      final b = DatabaseBundle.fromRaw(db);
      for (final country in b.countries) {
        final all = b.channelsFor(country.code);
        var sum = 0;
        for (final cat in b.categories.where((c) => c.id != Category.all)) {
          final sub = b.channelsFor(country.code, category: cat.id);
          expect(sub.every((c) => c.category == cat.id), isTrue);
          sum += sub.length;
        }
        expect(sum, all.length, reason: country.code);
      }
    });
  });

  group('SchemaValidator rejects bad data', () {
    test('duplicate ids', () {
      final db = copyDb(realDatabase());
      final my = ((db['channels.json']!['countries'] as List).first as Map)['channels'] as List;
      my.add(Map<String, dynamic>.from(my.first as Map));
      expect(SchemaValidator.validate(db).errors.join(), contains('duplicate id'));
    });

    test('http (cleartext) and non-allowlisted stream URLs', () {
      final db = copyDb(realDatabase());
      final my = ((db['channels.json']!['countries'] as List).first as Map)['channels'] as List;
      (my[0] as Map)
        ..['stream_type'] = 'hls'
        ..['stream_url'] = 'http://insecure.example.com/a.m3u8';
      (my[1] as Map)
        ..['stream_type'] = 'hls'
        ..['stream_url'] = 'https://random-pirate.example.net/a.m3u8';
      final e = SchemaValidator.validate(db).errors.join('\n');
      expect(e, contains('not_https'));
      expect(e, contains('domain_not_allowed'));
    });

    test('online without last_checked', () {
      final db = playableDb();
      final my = ((db['channels.json']!['countries'] as List).first as Map)['channels'] as List;
      (my[0] as Map)
        ..['availability'] = 'online'
        ..['last_checked'] = null;
      expect(SchemaValidator.validate(db).errors.join(), contains('requires last_checked'));
    });

    test('version mismatch, unknown category, dangling alternative, missing file', () {
      final db = copyDb(realDatabase());
      db['channels.json']!['version'] = 99;
      final my = ((db['channels.json']!['countries'] as List).first as Map)['channels'] as List;
      (my[0] as Map)['category'] = 'cooking';
      (my[1] as Map)['alternatives'] = ['my_does_not_exist'];
      final e = SchemaValidator.validate(db).errors.join('\n');
      expect(e, contains('must equal'));
      expect(e, contains('cooking'));
      expect(e, contains('my_does_not_exist'));
      final missing = <String, Map<String, dynamic>?>{...db}..['epg.json'] = null;
      expect(SchemaValidator.validate(missing).isValid, isFalse);
    });

    test('invalid EPG programme', () {
      final db = copyDb(realDatabase());
      db['epg.json']!['programs'] = {
        'my_tv1': [
          {'start': '2026-11-15T21:00:00+08:00', 'end': '2026-11-15T20:00:00+08:00', 'title': 'x'}
        ]
      };
      expect(SchemaValidator.validate(db).errors.join(), contains('epg.json'));
    });
  });

  group('DatabaseRepository update flow', () {
    test('first run without cache uses bundled data', () async {
      final repo = repoWith(realDatabase(), serve({}), MemoryCacheStore());
      final b = await repo.loadLocal();
      expect(repo.source, DatabaseSource.bundled);
      expect(b.version, v0);
    });

    test('downloads, validates and caches a newer version', () async {
      final cache = MemoryCacheStore();
      final repo = repoWith(realDatabase(), serve(playableDb(version: v0 + 1)), cache);
      await repo.loadLocal();
      final r = await repo.checkForUpdate();
      expect(r.outcome, UpdateOutcome.updated);
      expect(repo.current!.version, v0 + 1);
      expect(cache.value, isNotNull);

      // A fresh start (offline) now loads the cache, not the bundle.
      final offline = repoWith(realDatabase(), MockClient((_) async => throw http.ClientException('offline')), cache);
      final b = await offline.loadLocal();
      expect(offline.source, DatabaseSource.cache);
      expect(b.version, v0 + 1);
      expect(b.byId('my_tv1')!.hasDirectStream, isTrue);
    });

    test('same version: only app_config.json is downloaded', () async {
      final log = <String>[];
      final repo = repoWith(realDatabase(), serve(realDatabase(), log: log), MemoryCacheStore());
      final r = await repo.checkForUpdate();
      expect(r.outcome, UpdateOutcome.upToDate);
      expect(log, ['app_config.json']);
    });

    test('manual update forces a full download', () async {
      final log = <String>[];
      final repo = repoWith(realDatabase(), serve(realDatabase(), log: log), MemoryCacheStore());
      final r = await repo.checkForUpdate(force: true);
      expect(r.outcome, UpdateOutcome.updated);
      expect(log.toSet(), DatabaseBundle.fileNames.toSet());
    });

    test('invalid remote JSON keeps the old cache', () async {
      final cache = MemoryCacheStore();
      final good = repoWith(realDatabase(), serve(playableDb(version: v0 + 1)), cache);
      await good.checkForUpdate();
      final before = cache.value;

      final bad = playableDb(version: v0 + 2);
      ((bad['channels.json']!['countries'] as List).first as Map)['channels'] = 'not-a-list';
      final repo = repoWith(realDatabase(), serve(bad), cache);
      await repo.loadLocal();
      final r = await repo.checkForUpdate();
      expect(r.outcome, UpdateOutcome.failedInvalid);
      expect(cache.value, before);
      expect(repo.current!.version, v0 + 1);
    });

    test('network failure half-way keeps the old cache', () async {
      final cache = MemoryCacheStore();
      final repo = repoWith(realDatabase(), serve(playableDb(version: v0 + 4), fail: {'epg.json'}), cache);
      await repo.loadLocal();
      final r = await repo.checkForUpdate();
      expect(r.outcome, UpdateOutcome.failedNetwork);
      expect(cache.value, isNull);
      expect(repo.current!.version, v0);
    });

    test('corrupt cache falls back to bundled data', () async {
      final cache = MemoryCacheStore()..value = '{"app_config.json": 1';
      final repo = repoWith(realDatabase(), serve({}), cache);
      await repo.loadLocal();
      expect(repo.source, DatabaseSource.bundled);
    });

    test('database that needs a newer app build is not applied', () async {
      final remote = playableDb(version: v0 + 3);
      remote['app_config.json']!['min_app_build'] = 99;
      final repo = repoWith(realDatabase(), serve(remote), MemoryCacheStore());
      final r = await repo.checkForUpdate();
      expect(r.outcome, UpdateOutcome.appTooOld);
      expect(repo.current!.version, v0);
    });

    test('repoRootUrl is derived from the database URL', () {
      final repo = repoWith(realDatabase(), serve({}), MemoryCacheStore());
      expect(repo.repoRootUrl, 'https://raw.githubusercontent.com/o/r/main/');
    });
  });
}
