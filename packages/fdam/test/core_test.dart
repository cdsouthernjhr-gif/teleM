import 'package:fdam/fdam.dart';
import 'package:fdam/src/core/logger.dart' show redactText;
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> validManifest() => {
      'schemaVersion': 1,
      'appId': 'com.example.myapp',
      'releaseVersion': '1.0.0',
      'minimumManagerVersion': '1.0.0',
      'generatedAt': '2026-11-14T10:00:00Z',
      'assets': [
        {
          'id': 'audio_pack_01',
          'name': 'audio.zip',
          'category': 'audio',
          'version': '1.0.0',
          'url': 'https://github.com/USERNAME/REPOSITORY/releases/download/v1.0.0/audio.zip',
          'localPath': 'audio/audio.zip',
          'sizeBytes': 25000000,
          'sha256': 'a' * 64,
          'required': true,
          'downloadOnStartup': true,
          'extract': true,
        },
      ],
    };

void main() {
  const config = FdamConfig(manifestUrl: 'https://raw.githubusercontent.com/u/r/main/manifest/manifest.json', appId: 'com.example.myapp');

  group('AssetVersion', () {
    test('parses and orders semantic versions', () {
      expect(AssetVersion.parse('1.10.0') > AssetVersion.parse('1.9.9'), isTrue);
      expect(AssetVersion.parse('1.0.0') > AssetVersion.parse('1.0.0-rc.1'), isTrue);
      expect(AssetVersion.parse('1.0.0-rc.2') > AssetVersion.parse('1.0.0-rc.1'), isTrue);
      expect(AssetVersion.parse('2.0.0+build.5'), AssetVersion.parse('2.0.0'));
      expect(AssetVersion.tryParse('1.0'), isNull);
      expect(AssetVersion.tryParse('01.0.0'), isNull);
      expect(AssetVersion.tryParse('v1.0.0'), isNull);
      expect(compareVersionStrings('1.1.0', '1.0.9'), greaterThan(0));
    });
  });

  group('path safety', () {
    test('accepts normal relative paths', () {
      expect(relativePathProblem('audio/a.mp3'), isNull);
      expect(relativePathProblem('images/sub/b.png'), isNull);
      expect(relativePathProblem('dir/'), isNull);
    });
    test('rejects traversal, absolute and odd paths', () {
      for (final bad in [
        '../x',
        'a/../../x',
        '/etc/passwd',
        'C:/win',
        'a\\b',
        'a//b',
        './a',
        '~/.ssh',
        'a/\u0000b',
        '',
      ]) {
        expect(relativePathProblem(bad), isNotNull, reason: bad);
      }
    });
    test('safeJoin stays inside root', () {
      expect(safeJoin('/root/x', 'a/b.txt'), '/root/x/a/b.txt');
      expect(safeJoin('/root/x', '../y'), isNull);
    });
  });

  group('ManifestValidator', () {
    test('accepts the documented example (with a real-looking hash)', () {
      final r = ManifestValidator(config).validate(validManifest());
      expect(r.errors, isEmpty);
      final item = r.manifest!.assets.single;
      expect(item.priority, AssetPriority.required);
      expect(item.installRelativePath, 'assets/audio/audio');
    });

    test('rejects placeholder hash, bad appId, http, foreign host, traversal', () {
      Map<String, dynamic> mutate(void Function(Map<String, dynamic> a, Map<String, dynamic> root) f) {
        final m = validManifest();
        f((m['assets'] as List).first as Map<String, dynamic>, m);
        return m;
      }

      final cases = <String, Map<String, dynamic>>{
        'sha256': mutate((a, _) => a['sha256'] = 'REAL_SHA256_HASH'),
        'appId': mutate((_, r) => r['appId'] = 'com.other'),
        'not_https': mutate((a, _) => a['url'] = 'http://github.com/u/r/releases/download/v1/a.zip'),
        'host_not_allowed': mutate((a, _) => a['url'] = 'https://evil.example.com/a.zip'),
        'credentials': mutate((a, _) => a['url'] = 'https://user:pw@github.com/a.zip'),
        'traversal': mutate((a, _) => a['localPath'] = '../../databases/x.zip'),
        'absolute': mutate((a, _) => a['localPath'] = '/data/x.zip'),
        'category': mutate((a, _) => a['category'] = 'exe'),
        'size': mutate((a, _) => a['sizeBytes'] = 0),
        'version': mutate((a, _) => a['version'] = 'latest'),
        'extract_non_zip': mutate((a, _) {
          a['name'] = 'a.mp3';
          a['localPath'] = 'audio/a.mp3';
        }),
        'schema': mutate((_, r) => r['schemaVersion'] = 99),
      };
      cases.forEach((name, m) {
        final r = ManifestValidator(config).validate(m);
        expect(r.isValid, isFalse, reason: name);
      });
    });

    test('rejects duplicate ids and duplicate/overlapping paths', () {
      final m = validManifest();
      final a = Map<String, dynamic>.from((m['assets'] as List).first as Map);
      m['assets'] = <dynamic>[...m['assets'] as List, a];
      final r = ManifestValidator(config).validate(m);
      expect(r.errors.any((e) => e.contains('duplicate id')), isTrue);
      expect(r.errors.any((e) => e.contains('duplicate path')), isTrue);
    });

    test('flags a manifest that needs a newer manager as VERSION_CONFLICT', () {
      final m = validManifest()..['minimumManagerVersion'] = '9.0.0';
      final r = ManifestValidator(config).validate(m);
      expect(r.isValid, isFalse);
      expect(r.toException().code, FdamErrorCode.versionConflict);
    });

    test('rejects non-object roots and missing keys', () {
      expect(ManifestValidator(config).validate([]).isValid, isFalse);
      expect(ManifestValidator(config).validate({'schemaVersion': 1}).isValid, isFalse);
    });

    test('allowedUrlPrefixes restricts asset URLs to one repository', () {
      const strict = FdamConfig(
        manifestUrl: 'https://raw.githubusercontent.com/u/r/main/manifest/manifest.json',
        appId: 'com.example.myapp',
        allowedUrlPrefixes: ['https://github.com/OTHER/REPO/releases/download/'],
      );
      expect(ManifestValidator(strict).validate(validManifest()).isValid, isFalse);
    });
  });

  group('errors and logs', () {
    test('every error code has a user message in both languages', () {
      for (final c in FdamErrorCode.values) {
        expect(fdamErrorMessage(c, 'ms'), isNotEmpty);
        expect(fdamErrorMessage(c, 'en'), isNotEmpty);
      }
      expect(FdamErrorCode.fromWire('CHECKSUM_MISMATCH'), FdamErrorCode.checksumMismatch);
    });

    test('logs never contain query strings or credentials', () {
      final t = redactText('GET https://u:p@objects.githubusercontent.com/x/y.zip?X-Amz-Signature=secret failed');
      expect(t, isNot(contains('secret')));
      expect(t, isNot(contains('u:p')));
      expect(t, contains('objects.githubusercontent.com/x/y.zip?<redacted>'));
    });
  });
}
