import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fdam/fdam.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_env.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('fdam_zip_'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<String> writeZip(Uint8List bytes) async {
    final f = File('${tmp.path}/in.zip');
    await f.writeAsBytes(bytes);
    return f.path;
  }

  /// Builds a ZIP whose entry name is written verbatim (ZipEncoder would
  /// accept it too, but this makes the intent explicit).
  Uint8List zipWithName(String name) {
    final a = Archive()..addFile(ArchiveFile.bytes(name, [1, 2, 3]));
    return Uint8List.fromList(ZipEncoder().encodeBytes(a));
  }

  test('extracts files with progress into a new staging directory (isolate)', () async {
    final zip = await writeZip(makeZip({
      'a.txt': 'hello'.codeUnits,
      'sub/b.bin': randomBytes(200000),
      'sub/deeper/c.json': '{}'.codeUnits,
    }));
    final progress = <ZipProgress>[];
    final r = await const ZipExtractor().extract(zip, '${tmp.path}/out', onProgress: progress.add);
    expect(r.fileCount, 3);
    expect(r.totalBytes, 5 + 200000 + 2);
    expect(await File('${tmp.path}/out/sub/b.bin').length(), 200000);
    expect(progress.last.filesDone, 3);
    expect(progress.last.fraction, 1.0);
  });

  test('ZIP Slip: ../ entry is rejected and nothing is left behind', () async {
    final zip = await writeZip(zipWithName('../evil.txt'));
    await expectLater(
      const ZipExtractor().extract(zip, '${tmp.path}/out'),
      throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.invalidAssetPath)),
    );
    expect(await File('${tmp.path}/evil.txt').exists(), isFalse);
    expect(await Directory('${tmp.path}/out').exists(), isFalse);
  });

  test('absolute and nested traversal paths are rejected', () async {
    for (final name in ['/abs.txt', 'a/../../x.txt', 'a\\..\\x.txt']) {
      final zip = await writeZip(zipWithName(name));
      await expectLater(const ZipExtractor(useIsolate: false).extract(zip, '${tmp.path}/out'),
          throwsA(isA<FdamException>()), reason: name);
    }
  });

  test('symbolic links are rejected', () async {
    final a = Archive()..addFile(ArchiveFile.symlink('link', '/etc/passwd'));
    final zip = await writeZip(Uint8List.fromList(ZipEncoder().encodeBytes(a)));
    await expectLater(const ZipExtractor(useIsolate: false).extract(zip, '${tmp.path}/out'),
        throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.invalidAssetPath)));
  });

  test('entry count, total size and compression ratio limits', () async {
    final many = await writeZip(makeZip({for (var i = 0; i < 20; i++) 'f$i.txt': [i]}));
    await expectLater(
        const ZipExtractor(limits: ZipLimits(maxEntries: 10), useIsolate: false).extract(many, '${tmp.path}/o1'),
        throwsA(isA<FdamException>()));

    final big = await writeZip(makeZip({'a.bin': randomBytes(50000)}));
    await expectLater(
        const ZipExtractor(limits: ZipLimits(maxTotalUncompressedBytes: 1000), useIsolate: false)
            .extract(big, '${tmp.path}/o2'),
        throwsA(isA<FdamException>()));

    // 20 MB of zeros compresses ~1000:1 -> looks like a ZIP bomb.
    final bomb = await writeZip(makeZip({'zeros.bin': Uint8List(20 * 1024 * 1024)}, level: 9));
    await expectLater(const ZipExtractor(useIsolate: false).extract(bomb, '${tmp.path}/o3'),
        throwsA(isA<FdamException>().having((e) => e.detail, 'detail', contains('ratio'))));
  });

  test('insufficient space is reported before writing', () async {
    final zip = await writeZip(makeZip({'a.bin': randomBytes(100000)}));
    await expectLater(
      const ZipExtractor(useIsolate: false).extract(zip, '${tmp.path}/out', availableBytes: 1000),
      throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.diskSpaceInsufficient)),
    );
  });

  test('corrupt archive fails cleanly', () async {
    final zip = await writeZip(Uint8List.fromList(List.filled(1000, 7)));
    await expectLater(const ZipExtractor().extract(zip, '${tmp.path}/out'),
        throwsA(isA<FdamException>().having((e) => e.code, 'code', FdamErrorCode.zipExtractionFailed)));
    expect(await Directory('${tmp.path}/out').exists(), isFalse);
  });

  test('destination must not already exist', () async {
    final zip = await writeZip(makeZip({'a.txt': [1]}));
    await Directory('${tmp.path}/out').create();
    await expectLater(const ZipExtractor().extract(zip, '${tmp.path}/out'), throwsA(isA<FdamException>()));
  });
}
