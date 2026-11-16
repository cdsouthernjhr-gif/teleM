// Download engine: priority queue, limited concurrency, streaming to a
// `.part` file, HTTP Range resume validated with ETag/Last-Modified (If-Range),
// pause/resume/cancel, retry with exponential backoff, waiting for network,
// state persisted in SQLite, and size + SHA-256 verification.
//
// A download only counts as successful after the file on disk has the exact
// size and SHA-256 from the manifest.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';

import '../core/config.dart';
import '../core/errors.dart';
import '../core/logger.dart';
import '../integrity/hash_service.dart';
import '../manifest/models.dart';
import '../network/fdam_http.dart';
import '../network/network_monitor.dart';
import '../storage/fdam_database.dart';
import '../storage/fdam_paths.dart';

enum _StopReason { pause, cancel }

class _Stopped implements Exception {
  _Stopped(this.reason);
  final _StopReason reason;
}

class _Job {
  _Job(this.item, this.task, this.seq);

  final AssetItem item;
  DownloadTask task;
  final int seq;
  Completer<String> completer = Completer<String>();
  CancelToken? token;
  _StopReason? stop;
  Completer<void>? wake;
  bool running = false;
  int retries = 0;

  void interrupt(_StopReason r) {
    stop = r;
    token?.cancel(r.name);
    if (wake != null && !wake!.isCompleted) wake!.complete();
  }
}

typedef BoolGetter = bool Function();

class DownloadEngine {
  DownloadEngine({
    required this.config,
    required this.http,
    required this.db,
    required this.paths,
    required this.network,
    this.hash = const HashService(),
    BoolGetter? wifiOnly,
    FdamLogger? logger,
    Random? random,
  })  : wifiOnly = wifiOnly ?? (() => false),
        log = logger ?? FdamLogger(),
        _random = random ?? Random();

  final FdamConfig config;
  final FdamHttp http;
  final FdamDatabase db;
  final FdamPaths paths;
  final NetworkMonitor network;
  final HashService hash;
  final BoolGetter wifiOnly;
  final FdamLogger log;
  final Random _random;

  final Map<String, _Job> _jobs = {};
  final _updates = StreamController<DownloadTask>.broadcast();
  int _seq = 0;
  int _running = 0;
  bool _disposed = false;

  /// Emits a snapshot every time a task changes (progress is throttled).
  Stream<DownloadTask> get updates => _updates.stream;

  Map<String, DownloadTask> get tasks => {for (final j in _jobs.values) j.item.id: j.task};

  bool isActive(String assetId) => _jobs[assetId]?.task.status.isActive ?? false;

  /// Queues [item]. Completes with the path of the verified file, or throws
  /// [FdamException]. Calling it again for the same asset and hash returns
  /// the same future (no duplicate download).
  ///
  /// With [startPaused] the task is restored in the paused state (e.g. a
  /// download the user paused before the app was closed); [resume] starts it.
  Future<String> enqueue(AssetItem item, {bool startPaused = false, int initialBytes = 0}) {
    if (_disposed) throw StateError('DownloadEngine disposed');
    final existing = _jobs[item.id];
    if (existing != null) {
      final same = existing.item.sha256 == item.sha256;
      if (same && !existing.completer.isCompleted) {
        if (existing.task.status == DownloadStatus.paused) resume(item.id);
        return existing.completer.future;
      }
      if (!same && !existing.completer.isCompleted) {
        // A newer version replaced the one being downloaded.
        existing.interrupt(_StopReason.cancel);
      }
      _jobs.remove(item.id);
    }
    final job = _Job(
      item,
      DownloadTask(
        assetId: item.id,
        assetName: item.name,
        category: item.category,
        version: item.version,
        url: item.url,
        temporaryPath: paths.partFile(item),
        totalBytes: item.sizeBytes,
        priority: item.priority,
        downloadedBytes: initialBytes.clamp(0, item.sizeBytes),
        status: startPaused ? DownloadStatus.paused : DownloadStatus.queued,
      ),
      _seq++,
    );
    _jobs[item.id] = job;
    _emit(job);
    unawaited(_persist(job));
    _pump();
    return job.completer.future;
  }

  void pause(String assetId) {
    final j = _jobs[assetId];
    if (j == null || j.task.status.isTerminal || j.task.status == DownloadStatus.paused) return;
    if (j.task.status == DownloadStatus.verifying) return; // too late to pause
    if (j.running) {
      j.interrupt(_StopReason.pause);
    } else {
      _setStatus(j, DownloadStatus.paused);
    }
  }

  void resume(String assetId) {
    final j = _jobs[assetId];
    if (j == null || j.task.status != DownloadStatus.paused) return;
    j.stop = null;
    _setStatus(j, DownloadStatus.queued);
    _pump();
  }

  void cancel(String assetId) {
    final j = _jobs[assetId];
    if (j == null || j.task.status.isTerminal) return;
    if (j.running) {
      j.interrupt(_StopReason.cancel);
    } else {
      unawaited(_finishCancelled(j));
    }
  }

  /// Restarts a failed or cancelled download. Returns the new future.
  Future<String>? retry(String assetId) {
    final j = _jobs[assetId];
    if (j == null) return null;
    if (j.task.status == DownloadStatus.failed || j.task.status == DownloadStatus.cancelled) {
      _jobs.remove(assetId);
      return enqueue(j.item);
    }
    if (j.task.status == DownloadStatus.paused) resume(assetId);
    return j.completer.future;
  }

  void pauseAll() {
    for (final id in _jobs.keys.toList()) {
      pause(id);
    }
  }

  void resumeAll() {
    for (final id in _jobs.keys.toList()) {
      resume(id);
    }
  }

  /// Wakes jobs that are waiting for network or sleeping before a retry.
  void nudge() {
    for (final j in _jobs.values) {
      if (j.wake != null && !j.wake!.isCompleted) j.wake!.complete();
    }
  }

  /// Removes finished tasks from [tasks].
  void clearFinished() {
    _jobs.removeWhere((_, j) => j.task.status.isTerminal);
  }

  Future<void> dispose() async {
    _disposed = true;
    for (final j in _jobs.values) {
      if (j.running) j.interrupt(_StopReason.pause);
    }
    await _updates.close();
  }

  // ---------------------------------------------------------------------

  void _pump() {
    if (_disposed) return;
    while (_running < config.maxConcurrentDownloads) {
      _Job? next;
      for (final j in _jobs.values) {
        if (j.running || j.task.status != DownloadStatus.queued) continue;
        if (next == null ||
            j.item.priority.level < next.item.priority.level ||
            (j.item.priority.level == next.item.priority.level && j.seq < next.seq)) {
          next = j;
        }
      }
      if (next == null) return;
      final job = next;
      job.running = true;
      _running++;
      unawaited(_run(job).whenComplete(() {
        job.running = false;
        _running--;
        _pump();
      }));
    }
  }

  Future<void> _run(_Job job) async {
    final item = job.item;
    while (true) {
      if (job.stop != null) return _handleStop(job);
      if (!await network.canDownload(wifiOnly: wifiOnly())) {
        _setStatus(job, DownloadStatus.waitingForNetwork);
        await _waitForNetwork(job);
        continue;
      }
      if (job.stop != null) return _handleStop(job);
      _setStatus(job, DownloadStatus.downloading, clearError: true);
      try {
        await _downloadOnce(job);
        _setStatus(job, DownloadStatus.verifying);
        await hash.verifyFile(job.task.temporaryPath, expectedSize: item.sizeBytes, expectedSha256: item.sha256);
        job.task = job.task.copyWith(status: DownloadStatus.completed, downloadedBytes: item.sizeBytes);
        _emit(job);
        await _persist(job);
        log.info('download', '${item.id} ${item.version} verified');
        if (!job.completer.isCompleted) job.completer.complete(job.task.temporaryPath);
        return;
      } on _Stopped {
        return _handleStop(job);
      } on FdamException catch (e) {
        if (job.stop != null) return _handleStop(job);
        if (e.code == FdamErrorCode.cancelled) return _handleStop(job..stop = _StopReason.cancel);
        if (e.code == FdamErrorCode.checksumMismatch) {
          await deletePath(job.task.temporaryPath);
          await _clearValidators(job);
          job.task = job.task.copyWith(downloadedBytes: 0);
        }
        log.warn('download', '${item.id} attempt ${job.retries + 1} failed: ${e.code.wireName} ${e.detail}');
        if (!e.retryable || job.retries >= config.maxRetries) {
          job.task = job.task.copyWith(
              status: DownloadStatus.failed, lastError: e.code, lastErrorDetail: e.detail, bytesPerSecond: 0);
          _emit(job);
          await _persist(job, error: e);
          if (!job.completer.isCompleted) job.completer.completeError(e);
          return;
        }
        job.retries++;
        job.task = job.task.copyWith(
            retryCount: job.retries, lastError: e.code, lastErrorDetail: e.detail, bytesPerSecond: 0);
        _setStatus(job, DownloadStatus.queued);
        await _persist(job, error: e);
        await _sleep(job, _backoff(job.retries));
      } catch (e) {
        // Unexpected error (I/O): never crash the queue.
        final fe = e is FileSystemException
            ? FdamException(FdamErrorCode.diskSpaceInsufficient, 'file system: ${e.osError?.message ?? e.message}')
            : FdamException(FdamErrorCode.unknown, '${e.runtimeType}: $e');
        job.task = job.task.copyWith(status: DownloadStatus.failed, lastError: fe.code, lastErrorDetail: fe.detail);
        _emit(job);
        await _persist(job, error: fe);
        if (!job.completer.isCompleted) job.completer.completeError(fe);
        return;
      }
    }
  }

  Future<void> _handleStop(_Job job) async {
    if (job.stop == _StopReason.cancel) return _finishCancelled(job);
    job.task = job.task.copyWith(status: DownloadStatus.paused, bytesPerSecond: 0);
    _emit(job);
    await _persist(job);
    log.info('download', '${job.item.id} paused at ${job.task.downloadedBytes} bytes');
  }

  Future<void> _finishCancelled(_Job job) async {
    job.task = job.task.copyWith(status: DownloadStatus.cancelled, bytesPerSecond: 0, downloadedBytes: 0);
    _emit(job);
    await deletePath(job.task.temporaryPath);
    try {
      await db.deleteDownload(job.item.id);
    } catch (_) {}
    if (!job.completer.isCompleted) {
      job.completer.completeError(FdamException(FdamErrorCode.cancelled, 'cancelled by user'));
    }
    log.info('download', '${job.item.id} cancelled');
  }

  Duration _backoff(int attempt) {
    final base = config.retryBaseDelay.inMilliseconds * pow(2, attempt - 1);
    final capped = min(base.toDouble(), config.retryMaxDelay.inMilliseconds.toDouble());
    final jitter = capped * 0.2 * _random.nextDouble();
    return Duration(milliseconds: (capped + jitter).round());
  }

  Future<void> _sleep(_Job job, Duration d) async {
    job.wake = Completer<void>();
    final t = Timer(d, () {
      if (!job.wake!.isCompleted) job.wake!.complete();
    });
    await job.wake!.future;
    t.cancel();
  }

  Future<void> _waitForNetwork(_Job job) async {
    job.wake = Completer<void>();
    final sub = network.changes.listen((s) {
      if (s.internetReachable == true && !job.wake!.isCompleted) job.wake!.complete();
    });
    // Re-check periodically too: Wi-Fi-only rules or a missed event.
    final t = Timer(const Duration(seconds: 30), () {
      if (!job.wake!.isCompleted) job.wake!.complete();
    });
    await job.wake!.future;
    t.cancel();
    await sub.cancel();
  }

  Future<void> _clearValidators(_Job job) async {
    try {
      await db.upsertDownload(
        item: job.item,
        temporaryPath: job.task.temporaryPath,
        downloadedBytes: 0,
        status: job.task.status,
        clearValidators: true,
      );
    } catch (_) {}
  }

  static String? _strongEtag(String? etag) {
    if (etag == null || etag.isEmpty || etag.startsWith('W/')) return null;
    return etag;
  }

  Future<void> _downloadOnce(_Job job) async {
    final item = job.item;
    final part = File(job.task.temporaryPath);
    await part.parent.create(recursive: true);
    var existing = await part.exists() ? await part.length() : 0;
    final rec = await db.download(item.id);
    final sameVersion = rec != null && rec.sha256 == item.sha256;
    final validator = sameVersion ? (rec.etag ?? rec.lastModified) : null;

    if (existing > item.sizeBytes || (existing > 0 && validator == null && existing < item.sizeBytes)) {
      // Cannot prove the partial file belongs to this resource: start over.
      await deletePath(part.path);
      existing = 0;
    }
    if (existing == item.sizeBytes) {
      job.task = job.task.copyWith(downloadedBytes: existing);
      return; // complete on disk, verification decides
    }

    final headers = <String, String>{HttpHeaders.acceptEncodingHeader: 'identity'};
    if (existing > 0) {
      headers[HttpHeaders.rangeHeader] = 'bytes=$existing-';
      headers['If-Range'] = validator!;
    }
    job.token = CancelToken();
    final resp = await http.getStream(item.url, headers: headers, cancelToken: job.token);
    final code = resp.statusCode ?? 0;

    bool append;
    if (code == 206 && existing > 0) {
      final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
      final m = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(cr.trim());
      final startOk = m != null && int.parse(m[1]!) == existing;
      final totalOk = m != null && (m[3] == '*' || int.parse(m[3]!) == item.sizeBytes);
      if (!startOk || !totalOk) {
        await FdamHttp.discard(resp);
        await deletePath(part.path);
        await _clearValidators(job);
        throw FdamException(FdamErrorCode.downloadInterrupted, 'unexpected Content-Range "$cr"', retryable: true);
      }
      append = true;
    } else if (code == 200) {
      if (existing > 0) log.info('download', '${item.id}: server sent full file, restarting');
      append = false;
      existing = 0;
    } else {
      await FdamHttp.discard(resp);
      if (code == 416) {
        await deletePath(part.path);
        await _clearValidators(job);
        throw FdamException(FdamErrorCode.downloadInterrupted, 'HTTP 416, restarting', retryable: true);
      }
      if (code == 404 || code == 410) {
        throw FdamException(FdamErrorCode.fileNotFound, 'HTTP $code: ${redactUrl(item.url)}', httpStatus: code);
      }
      throw FdamException(FdamErrorCode.httpError, 'HTTP $code: ${redactUrl(item.url)}',
          httpStatus: code, retryable: code >= 500 || code == 429 || code == 408);
    }

    final expectedBody = item.sizeBytes - existing;
    final lenHeader = int.tryParse(resp.headers.value(HttpHeaders.contentLengthHeader) ?? '');
    if (lenHeader != null && lenHeader >= 0 && lenHeader != expectedBody) {
      await FdamHttp.discard(resp);
      if (!append) await deletePath(part.path);
      throw FdamException(FdamErrorCode.checksumMismatch,
          'Content-Length $lenHeader != expected $expectedBody (manifest out of date?)',
          retryable: true);
    }

    final etag = _strongEtag(resp.headers.value(HttpHeaders.etagHeader));
    final lastMod = resp.headers.value(HttpHeaders.lastModifiedHeader);
    await db.upsertDownload(
      item: item,
      temporaryPath: part.path,
      downloadedBytes: existing,
      status: DownloadStatus.downloading,
      retryCount: job.retries,
      etag: etag,
      lastModified: etag == null ? lastMod : null,
      clearValidators: true,
    );

    final raf = await part.open(mode: append ? FileMode.append : FileMode.write);
    var received = existing;
    final samples = <(DateTime, int)>[(DateTime.now(), received)];
    var lastEmit = DateTime.now();
    var lastPersist = DateTime.now();
    job.task = job.task.copyWith(downloadedBytes: received);
    _emit(job);
    try {
      await for (final chunk in resp.data!.stream) {
        if (job.stop != null) throw _Stopped(job.stop!);
        received += chunk.length;
        if (received > item.sizeBytes) {
          throw FdamException(FdamErrorCode.checksumMismatch, 'server sent more bytes than the manifest size',
              retryable: true);
        }
        await raf.writeFrom(chunk);
        final now = DateTime.now();
        if (now.difference(lastEmit).inMilliseconds >= 200) {
          samples.add((now, received));
          while (samples.length > 2 && now.difference(samples.first.$1).inMilliseconds > 3000) {
            samples.removeAt(0);
          }
          final dt = now.difference(samples.first.$1).inMilliseconds;
          final speed = dt > 0 ? (received - samples.first.$2) * 1000 / dt : 0.0;
          job.task = job.task.copyWith(downloadedBytes: received, bytesPerSecond: speed);
          _emit(job);
          lastEmit = now;
        }
        if (now.difference(lastPersist).inSeconds >= 2) {
          await raf.flush();
          job.task = job.task.copyWith(downloadedBytes: received);
          unawaited(_persist(job));
          lastPersist = now;
        }
      }
    } on DioException catch (e) {
      if (job.stop != null) throw _Stopped(job.stop!);
      throw mapDioError(e, item.url);
    } on _Stopped {
      rethrow;
    } on FdamException {
      rethrow;
    } on FileSystemException {
      rethrow;
    } catch (e) {
      if (job.stop != null) throw _Stopped(job.stop!);
      throw FdamException(FdamErrorCode.downloadInterrupted, 'stream error ${e.runtimeType}', retryable: true);
    } finally {
      try {
        await raf.flush();
      } catch (_) {}
      await raf.close();
      job.task = job.task.copyWith(downloadedBytes: received);
      job.token = null;
    }
    await _persist(job);
    if (received != item.sizeBytes) {
      throw FdamException(FdamErrorCode.downloadInterrupted, 'stream ended at $received of ${item.sizeBytes}',
          retryable: true);
    }
  }

  void _setStatus(_Job job, DownloadStatus s, {bool clearError = false}) {
    job.task = job.task.copyWith(
        status: s, clearError: clearError, bytesPerSecond: s == DownloadStatus.downloading ? null : 0);
    _emit(job);
    unawaited(_persist(job));
  }

  void _emit(_Job job) {
    if (!_updates.isClosed) _updates.add(job.task);
  }

  Future<void> _persist(_Job job, {FdamException? error}) async {
    try {
      await db.upsertDownload(
        item: job.item,
        temporaryPath: job.task.temporaryPath,
        downloadedBytes: job.task.downloadedBytes,
        status: job.task.status,
        retryCount: job.retries,
        lastError: error == null ? null : '${error.code.wireName}: ${error.detail}',
      );
    } catch (e) {
      log.warn('download', 'persist failed for ${job.item.id}: $e');
    }
  }
}
