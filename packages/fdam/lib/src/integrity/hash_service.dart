// Streaming SHA-256 in a background isolate (never loads a whole file in RAM
// and never blocks the UI thread).

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../core/errors.dart';

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Synchronous worker; runs inside [Isolate.run].
String _sha256OfFileSync(String path) {
  final raf = File(path).openSync();
  try {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    const chunk = 1 << 20;
    while (true) {
      final bytes = raf.readSync(chunk);
      if (bytes.isEmpty) break;
      input.add(bytes);
    }
    input.close();
    return sink.value.toString();
  } finally {
    raf.closeSync();
  }
}

class HashService {
  const HashService({this.useIsolate = true});

  final bool useIsolate;

  Future<String> sha256OfFile(String path) async {
    if (!useIsolate) return _sha256OfFileSync(path);
    return Isolate.run(() => _sha256OfFileSync(path), debugName: 'fdam-sha256');
  }

  /// Checks size first (cheap) then SHA-256. Throws [FdamException] with
  /// [FdamErrorCode.checksumMismatch] on any difference.
  Future<void> verifyFile(String path, {required int expectedSize, required String expectedSha256}) async {
    final f = File(path);
    if (!await f.exists()) {
      throw FdamException(FdamErrorCode.fileNotFound, 'file to verify is missing');
    }
    final len = await f.length();
    if (len != expectedSize) {
      throw FdamException(FdamErrorCode.checksumMismatch, 'size $len != expected $expectedSize', retryable: true);
    }
    final actual = await sha256OfFile(path);
    if (actual != expectedSha256.toLowerCase()) {
      throw FdamException(FdamErrorCode.checksumMismatch,
          'sha256 ${actual.substring(0, 12)}… != expected ${expectedSha256.substring(0, 12)}…',
          retryable: true);
    }
  }
}
