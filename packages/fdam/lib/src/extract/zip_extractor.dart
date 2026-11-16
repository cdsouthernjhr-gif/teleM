// Safe ZIP extraction in a background isolate.
//
// Protections: ZIP Slip / path traversal, absolute paths, symbolic links,
// duplicate entries, entry count limit, total uncompressed size limit,
// compression-ratio limit (ZIP bombs), real byte counting while writing (a
// lying header cannot write more than it declared), free space check.
// Always extracts into a fresh staging directory which is deleted on error.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/errors.dart';
import '../core/path_safety.dart';

class ZipExtractionResult {
  const ZipExtractionResult({required this.fileCount, required this.totalBytes, required this.directory});
  final int fileCount;
  final int totalBytes;
  final String directory;
}

class ZipProgress {
  const ZipProgress(this.filesDone, this.filesTotal, this.bytesDone, this.bytesTotal);
  final int filesDone;
  final int filesTotal;
  final int bytesDone;
  final int bytesTotal;
  double get fraction => bytesTotal > 0 ? (bytesDone / bytesTotal).clamp(0.0, 1.0) : 0.0;
}

class ZipExtractor {
  const ZipExtractor({this.limits = const ZipLimits(), this.useIsolate = true});

  final ZipLimits limits;
  final bool useIsolate;

  /// Extracts [zipPath] into [destination], which must not exist yet.
  /// [availableBytes] (if known) is compared with the declared total size.
  Future<ZipExtractionResult> extract(
    String zipPath,
    String destination, {
    int? availableBytes,
    int safetyMarginBytes = 0,
    void Function(ZipProgress)? onProgress,
  }) async {
    if (await FileSystemEntity.type(destination) != FileSystemEntityType.notFound) {
      throw FdamException(FdamErrorCode.zipExtractionFailed, 'destination already exists');
    }
    final args = _Args(zipPath, destination, limits.maxEntries, limits.maxTotalUncompressedBytes,
        limits.maxCompressionRatio, limits.allowSymlinks, availableBytes, safetyMarginBytes);
    try {
      if (!useIsolate) {
        return _extractSync(args, (pr) => onProgress?.call(pr));
      }
      return await _runInIsolate(args, onProgress);
    } catch (e) {
      // Never leave a half-extracted directory behind.
      try {
        final d = Directory(destination);
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {}
      if (e is FdamException) rethrow;
      throw FdamException(FdamErrorCode.zipExtractionFailed, '${e.runtimeType}: $e');
    }
  }

  Future<ZipExtractionResult> _runInIsolate(_Args args, void Function(ZipProgress)? onProgress) async {
    final port = ReceivePort();
    final errors = ReceivePort();
    final exit = ReceivePort();
    final done = Completer<ZipExtractionResult>();
    await Isolate.spawn<(SendPort, _Args)>(_entry, (port.sendPort, args),
        onError: errors.sendPort, onExit: exit.sendPort, debugName: 'fdam-unzip');
    port.listen((msg) {
      if (msg is List && msg.isNotEmpty) {
        switch (msg[0]) {
          case 'p':
            onProgress?.call(ZipProgress(msg[1] as int, msg[2] as int, msg[3] as int, msg[4] as int));
          case 'ok':
            if (!done.isCompleted) {
              done.complete(ZipExtractionResult(
                  fileCount: msg[1] as int, totalBytes: msg[2] as int, directory: args.destination));
            }
          case 'err':
            if (!done.isCompleted) {
              done.completeError(FdamException(FdamErrorCode.fromWire(msg[1] as String), msg[2] as String));
            }
        }
      }
    });
    errors.listen((e) {
      if (!done.isCompleted) {
        done.completeError(FdamException(FdamErrorCode.zipExtractionFailed, 'isolate error: $e'));
      }
    });
    exit.listen((_) {
      if (!done.isCompleted) {
        done.completeError(FdamException(FdamErrorCode.zipExtractionFailed, 'isolate exited unexpectedly'));
      }
    });
    try {
      return await done.future;
    } finally {
      port.close();
      errors.close();
      exit.close();
    }
  }

  static void _entry((SendPort, _Args) msg) {
    final (send, args) = msg;
    try {
      final r = _extractSync(
          args, (pr) => send.send(['p', pr.filesDone, pr.filesTotal, pr.bytesDone, pr.bytesTotal]));
      send.send(['ok', r.fileCount, r.totalBytes]);
    } on FdamException catch (e) {
      send.send(['err', e.code.wireName, e.detail]);
    } catch (e) {
      send.send(['err', FdamErrorCode.zipExtractionFailed.wireName, '${e.runtimeType}: $e']);
    }
  }
}

class _Args {
  const _Args(this.zipPath, this.destination, this.maxEntries, this.maxTotal, this.maxRatio, this.allowSymlinks,
      this.available, this.margin);
  final String zipPath;
  final String destination;
  final int maxEntries;
  final int maxTotal;
  final double maxRatio;
  final bool allowSymlinks;
  final int? available;
  final int margin;
}

FdamException _bad(String m) => FdamException(FdamErrorCode.zipExtractionFailed, m);
FdamException _badPath(String m) => FdamException(FdamErrorCode.invalidAssetPath, m);

ZipExtractionResult _extractSync(_Args a, void Function(ZipProgress) progress) {
  final zipFile = File(a.zipPath);
  final zipLen = zipFile.lengthSync();
  final input = InputFileStream(a.zipPath);
  try {
    final decoder = ZipDecoder();
    final Archive archive;
    try {
      archive = decoder.decodeStream(input, throwOnError: true);
    } catch (e) {
      throw _bad('not a valid ZIP: ${e.runtimeType}');
    }
    // Check the raw central-directory names too, in case the decoder
    // rewrites a name before it reaches ArchiveFile.
    for (final h in decoder.directory.fileHeaders) {
      final problem = relativePathProblem(h.filename);
      if (problem != null) throw _badPath('unsafe entry "${h.filename}" ($problem)');
    }
    final headers = {for (final h in decoder.directory.fileHeaders) h.filename: h};
    final entries = archive.files;
    if (entries.isEmpty) throw _bad('archive is empty or not a ZIP');
    if (entries.length > a.maxEntries) throw _bad('too many entries (${entries.length} > ${a.maxEntries})');

    final destRoot = p.normalize(p.absolute(a.destination));
    final seen = <String>{};
    var declaredTotal = 0;
    var fileTotal = 0;
    final plan = <(ArchiveFile, String)>[];

    for (final e in entries) {
      final name = e.name;
      final problem = relativePathProblem(name);
      if (problem != null) throw _badPath('unsafe entry "$name" ($problem)');
      if (e.isSymbolicLink && !a.allowSymlinks) throw _badPath('symbolic link not allowed: "$name"');
      final h = headers[name];
      final mode = (h?.externalFileAttributes ?? 0) >> 16;
      if (!a.allowSymlinks && (mode & 0xF000) == 0xA000) throw _badPath('symbolic link not allowed: "$name"');
      final clean = name.endsWith('/') ? name.substring(0, name.length - 1) : name;
      final target = safeJoin(destRoot, clean);
      if (target == null) throw _badPath('entry escapes destination: "$name"');
      if (!seen.add(clean.toLowerCase())) throw _badPath('duplicate entry "$name"');
      if (e.isFile) {
        if (e.size < 0) throw _bad('negative size for "$name"');
        declaredTotal += e.size;
        fileTotal++;
        final compressed = h?.compressedSize ?? 0;
        if (e.size > 1024 * 1024 && compressed > 0 && e.size / compressed > a.maxRatio) {
          throw _bad('suspicious compression ratio for "$name"');
        }
      }
      plan.add((e, target));
    }
    if (declaredTotal > a.maxTotal) throw _bad('uncompressed size $declaredTotal exceeds limit ${a.maxTotal}');
    if (declaredTotal > 1024 * 1024 && zipLen > 0 && declaredTotal / zipLen > a.maxRatio) {
      throw _bad('suspicious overall compression ratio');
    }
    if (a.available != null && declaredTotal + a.margin > a.available!) {
      throw FdamException(FdamErrorCode.diskSpaceInsufficient,
          'need ${declaredTotal + a.margin} bytes to extract, ${a.available} available');
    }

    Directory(destRoot).createSync(recursive: true);
    var filesDone = 0;
    var bytesDone = 0;
    var lastReport = DateTime.now();
    progress(ZipProgress(0, fileTotal, 0, declaredTotal));
    for (final (e, target) in plan) {
      if (!e.isFile) {
        Directory(target).createSync(recursive: true);
        continue;
      }
      Directory(p.dirname(target)).createSync(recursive: true);
      if (FileSystemEntity.typeSync(target, followLinks: false) != FileSystemEntityType.notFound) {
        throw _badPath('entry collides with an existing path: "${e.name}"');
      }
      final out = _LimitedOutput(OutputFileStream(target), e.size);
      try {
        e.writeContent(out);
      } on FdamException {
        rethrow;
      } catch (err) {
        throw _bad('cannot extract "${e.name}": ${err.runtimeType}');
      } finally {
        out.closeSync();
      }
      if (out.written != e.size) throw _bad('size mismatch for "${e.name}" (${out.written} != ${e.size})');
      bytesDone += out.written;
      filesDone++;
      final now = DateTime.now();
      if (now.difference(lastReport).inMilliseconds > 150 || filesDone == fileTotal) {
        progress(ZipProgress(filesDone, fileTotal, bytesDone, declaredTotal));
        lastReport = now;
      }
    }
    return ZipExtractionResult(fileCount: filesDone, totalBytes: bytesDone, directory: destRoot);
  } finally {
    input.closeSync();
  }
}

/// Counts bytes and refuses to write more than the entry declared.
class _LimitedOutput extends OutputStream {
  _LimitedOutput(this._inner, this.limit) : super(byteOrder: ByteOrder.littleEndian);

  final OutputFileStream _inner;
  final int limit;
  int written = 0;

  void _add(int n) {
    written += n;
    if (written > limit) throw _bad('entry is larger than declared (possible ZIP bomb)');
  }

  @override
  int get length => _inner.length;
  @override
  void clear() => _inner.clear();
  @override
  void flush() => _inner.flush();
  @override
  void closeSync() => _inner.closeSync();
  @override
  Future<void> close() => _inner.close();
  @override
  void writeByte(int value) {
    _add(1);
    _inner.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _add(length ?? bytes.length);
    _inner.writeBytes(bytes, length: length);
  }

  @override
  void writeRange(Uint8List bytes, int start, int end) {
    _add(end - start);
    _inner.writeRange(bytes, start, end);
  }

  @override
  void writeStream(InputStream stream) {
    _add(stream.length);
    _inner.writeStream(stream);
  }

  @override
  Uint8List subset(int start, [int? end]) => _inner.subset(start, end);
}
