// Real free-space information. On Android this uses StatFs through the FDAM
// plugin; on desktop/test hosts it falls back to `df`.

import 'dart:io';

import 'package:flutter/services.dart';

class StorageSpace {
  const StorageSpace({required this.availableBytes, required this.totalBytes});
  final int availableBytes;
  final int totalBytes;
}

abstract class StorageInfoProvider {
  /// Null when the free space cannot be determined.
  Future<StorageSpace?> spaceFor(String path);
}

class PlatformStorageInfo implements StorageInfoProvider {
  const PlatformStorageInfo();

  static const MethodChannel _channel = MethodChannel('dev.fdam/storage');

  @override
  Future<StorageSpace?> spaceFor(String path) async {
    if (Platform.isAndroid) {
      try {
        final m = await _channel.invokeMapMethod<String, Object?>('getStorageInfo', {'path': path});
        if (m == null) return null;
        return StorageSpace(
          availableBytes: (m['availableBytes'] as num).toInt(),
          totalBytes: (m['totalBytes'] as num).toInt(),
        );
      } catch (_) {
        return null;
      }
    }
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        final r = await Process.run('df', ['-Pk', path]);
        if (r.exitCode != 0) return null;
        final lines = (r.stdout as String).trim().split('\n');
        final cols = lines.last.split(RegExp(r'\s+'));
        return StorageSpace(availableBytes: int.parse(cols[3]) * 1024, totalBytes: int.parse(cols[1]) * 1024);
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}

/// Fixed values, for tests.
class FixedStorageInfo implements StorageInfoProvider {
  FixedStorageInfo(this.availableBytes, {this.totalBytes = 1 << 40});
  int availableBytes;
  final int totalBytes;

  @override
  Future<StorageSpace?> spaceFor(String path) async =>
      StorageSpace(availableBytes: availableBytes, totalBytes: totalBytes);
}
