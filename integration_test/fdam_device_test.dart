// Android device test for FDAM. Runs on a real phone / TV box / emulator:
//
//   flutter test integration_test/fdam_device_test.dart -d <device-id>
//
// It serves a generated release from a local HTTP server ON THE DEVICE, so it
// needs no GitHub repository, and exercises the real Android pieces: native
// sqflite, path_provider, StatFs (FDAM plugin), connectivity_plus, isolates.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fdam/fdam.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

Uint8List _bytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('FDAM on device: download, verify, extract, resume, update, offline', (tester) async {
    await tester.runAsync(() async {
      final files = <String, Uint8List>{};
      final etags = <String, String>{};
      var dropNextAfter = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final data = files[req.uri.path];
        final res = req.response;
        if (data == null) {
          res.statusCode = 404;
          await res.close();
          return;
        }
        final etag = etags[req.uri.path]!;
        res.headers.set('etag', etag);
        if (req.headers.value('if-none-match') == etag) {
          res.statusCode = 304;
          await res.close();
          return;
        }
        var start = 0;
        final range = req.headers.value('range');
        if (range != null && req.headers.value('if-range') == etag) {
          start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
          res.statusCode = 206;
          res.headers.set('content-range', 'bytes $start-${data.length - 1}/${data.length}');
        }
        final body = data.sublist(start);
        res.contentLength = body.length;
        if (dropNextAfter > 0 && dropNextAfter < body.length) {
          final cut = dropNextAfter;
          dropNextAfter = 0;
          final s = await res.detachSocket(writeHeaders: true);
          s.add(body.sublist(0, cut));
          await s.flush();
          s.destroy();
          return;
        }
        res.add(body);
        await res.close();
      });
      String url(String p) => 'http://127.0.0.1:${server.port}$p';
      void put(String p, Uint8List b) {
        files[p] = b;
        etags[p] = '"${sha256.convert(b).toString().substring(0, 16)}"';
      }

      final archive = Archive()
        ..addFile(ArchiveFile.bytes('a.wav', _bytes(300000, 1)))
        ..addFile(ArchiveFile.bytes('sub/b.wav', _bytes(100000, 2)));
      final zip = Uint8List.fromList(ZipEncoder().encodeBytes(archive));
      final img1 = _bytes(500000, 3);
      final img2 = _bytes(520000, 4);

      Map<String, dynamic> asset(String id, String name, String cat, Uint8List b, String v,
              {bool req = true, bool extract = false, required String lp}) =>
          {
            'id': id,
            'name': name,
            'category': cat,
            'version': v,
            'url': url('/dl/$v/$name'),
            'localPath': lp,
            'sizeBytes': b.length,
            'sha256': sha256.convert(b).toString(),
            'required': req,
            'downloadOnStartup': false,
            'extract': extract,
          };
      void publish(String release, List<Map<String, dynamic>> assets) => put(
          '/manifest.json',
          Uint8List.fromList(utf8.encode(jsonEncode({
            'schemaVersion': 1,
            'appId': 'com.myaseantv.tv',
            'releaseVersion': release,
            'minimumManagerVersion': '1.0.0',
            'generatedAt': '2026-11-16T00:00:00Z',
            'assets': assets,
          }))));

      put('/dl/1.0.0/audio.zip', zip);
      put('/dl/1.0.0/logo.png', img1);
      put('/dl/1.1.0/logo.png', img2);
      publish('1.0.0', [
        asset('audio', 'audio.zip', 'audio', zip, '1.0.0', extract: true, lp: 'audio/audio.zip'),
        asset('logo', 'logo.png', 'image', img1, '1.0.0', lp: 'images/logo.png'),
      ]);

      final support = await getApplicationSupportDirectory();
      final root = Directory('${support.path}/fdam_device_test');
      if (await root.exists()) await root.delete(recursive: true);
      final config = FdamConfig(
        manifestUrl: url('/manifest.json'),
        appId: 'com.myaseantv.tv',
        insecureHttpHosts: const {'127.0.0.1'},
        retryBaseDelay: const Duration(milliseconds: 100),
      );

      // Real Android implementations: sqflite, StatFs, connectivity_plus.
      var m = await AssetManager.create(config: config, rootDirectory: root, preferences: MemoryFdamPreferences());
      final space = await const PlatformStorageInfo().spaceFor(root.path);
      expect(space, isNotNull, reason: 'StatFs through the FDAM plugin');
      expect(space!.availableBytes, greaterThan(0));

      dropNextAfter = 200000; // connection drop in the middle of a file
      await m.checkForUpdates();
      expect(m.snapshot.phase, FdamPhase.needsSetup);
      final r = await m.downloadRequired();
      expect(r.failed, isEmpty, reason: r.failed.toString());
      expect(m.snapshot.phase, FdamPhase.ready);
      expect(await File('${(await m.pathOf('audio'))!}/sub/b.wav').length(), 100000);
      await m.dispose();
      await m.db.close();

      // "Restart" + update of the image only.
      publish('1.1.0', [
        asset('audio', 'audio.zip', 'audio', zip, '1.0.0', extract: true, lp: 'audio/audio.zip'),
        asset('logo', 'logo.png', 'image', img2, '1.1.0', lp: 'images/logo.png'),
      ]);
      m = await AssetManager.create(config: config, rootDirectory: root, preferences: MemoryFdamPreferences());
      final check = await m.checkForUpdates(autoDownload: false);
      expect(check.plan!.downloads.map((e) => e.id).toList(), ['logo']);
      expect((await m.applyUpdates()).allOk, isTrue);
      expect(await m.repository.getAssetVersion('logo'), '1.1.0');
      await m.dispose();
      await m.db.close();

      // Offline start.
      await server.close(force: true);
      m = await AssetManager.create(config: config, rootDirectory: root, preferences: MemoryFdamPreferences());
      expect(m.snapshot.phase, FdamPhase.ready);
      await m.checkForUpdates();
      expect(m.snapshot.phase, FdamPhase.ready);
      await m.dispose();
      await m.db.close();
      await root.delete(recursive: true);
    });
  });
}
