// Fetches manifest.json from GitHub (raw URL), validates it and keeps a cache
// for offline use. Uses ETag / Last-Modified so an unchanged manifest is not
// downloaded again.

import 'dart:convert';
import 'dart:io';

import '../core/config.dart';
import '../core/errors.dart';
import '../core/logger.dart';
import '../core/version.dart';
import '../network/fdam_http.dart';
import '../storage/fdam_paths.dart';
import 'manifest_validator.dart';
import 'models.dart';

enum ManifestSource { network, notModified, cache }

class ManifestResult {
  ManifestResult({
    required this.manifest,
    required this.source,
    required this.fetchedAt,
    this.previousReleaseVersion,
    this.networkError,
  });

  final AssetManifest manifest;
  final ManifestSource source;
  final DateTime fetchedAt;

  /// Release version of the cache before this fetch (null on first fetch).
  final String? previousReleaseVersion;

  /// Set when the network failed and the cache was used instead.
  final FdamException? networkError;

  bool get isOffline => source == ManifestSource.cache && networkError != null;

  bool get isNewRelease =>
      previousReleaseVersion != null && compareVersionStrings(manifest.releaseVersion, previousReleaseVersion!) > 0;
}

class CachedManifest {
  CachedManifest(this.manifest, this.etag, this.lastModified, this.fetchedAt);
  final AssetManifest manifest;
  final String? etag;
  final String? lastModified;
  final DateTime fetchedAt;
}

class ManifestReader {
  ManifestReader({required this.config, required this.http, required this.cacheFile, FdamLogger? logger})
      : validator = ManifestValidator(config),
        log = logger ?? FdamLogger();

  final FdamConfig config;
  final FdamHttp http;
  final File cacheFile;
  final ManifestValidator validator;
  final FdamLogger log;

  /// Reads the cached manifest. Returns null if absent or no longer valid
  /// (e.g. appId changed).
  Future<CachedManifest?> readCache() async {
    try {
      if (!await cacheFile.exists()) return null;
      final j = jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
      final res = validator.validate(j['manifest']);
      if (!res.isValid) {
        log.warn('manifest', 'cached manifest invalid: ${res.errors.take(2).join('; ')}');
        return null;
      }
      return CachedManifest(
        res.manifest!,
        j['etag'] as String?,
        j['lastModified'] as String?,
        DateTime.tryParse(j['fetchedAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (e) {
      log.warn('manifest', 'cache unreadable: ${e.runtimeType}');
      return null;
    }
  }

  Future<void> _writeCache(Map<String, dynamic> manifestJson, String? etag, String? lastModified, DateTime at) =>
      writeAtomic(
          cacheFile,
          jsonEncode({
            'etag': etag,
            'lastModified': lastModified,
            'fetchedAt': at.toUtc().toIso8601String(),
            'manifest': manifestJson,
          }));

  /// Gets the newest valid manifest.
  ///
  /// * Network OK + changed  -> validated, cached, [ManifestSource.network].
  /// * 304 Not Modified      -> cached copy, [ManifestSource.notModified].
  /// * Network failure       -> cached copy with [ManifestResult.networkError];
  ///                            throws when there is no cache.
  /// * Invalid / 404         -> throws, cache untouched.
  Future<ManifestResult> fetch({bool forceFull = false}) async {
    if (!config.isEnabled) {
      throw FdamException(FdamErrorCode.manifestNotFound, 'manifest URL not configured');
    }
    final cached = await readCache();
    final headers = <String, String>{HttpHeaders.acceptHeader: 'application/json'};
    if (cached != null && !forceFull) {
      if (cached.etag != null) headers[HttpHeaders.ifNoneMatchHeader] = cached.etag!;
      if (cached.lastModified != null) headers[HttpHeaders.ifModifiedSinceHeader] = cached.lastModified!;
    }

    try {
      final resp = await http.getStream(config.manifestUrl, headers: headers);
      final code = resp.statusCode ?? 0;
      if (code == 304 && cached != null) {
        await FdamHttp.discard(resp);
        log.info('manifest', 'not modified (release ${cached.manifest.releaseVersion})');
        return ManifestResult(
          manifest: cached.manifest,
          source: ManifestSource.notModified,
          fetchedAt: DateTime.now(),
          previousReleaseVersion: cached.manifest.releaseVersion,
        );
      }
      if (code == 404 || code == 410) {
        await FdamHttp.discard(resp);
        throw FdamException(FdamErrorCode.manifestNotFound, 'HTTP $code for manifest', httpStatus: code);
      }
      if (code != 200) {
        await FdamHttp.discard(resp);
        throw FdamException(FdamErrorCode.httpError, 'HTTP $code for manifest',
            httpStatus: code, retryable: code >= 500 || code == 429);
      }
      final body = await http.readBody(resp, config.maxManifestBytes);
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(body));
      } on FormatException catch (e) {
        throw FdamException(FdamErrorCode.manifestInvalid, 'not JSON: ${e.message}');
      }
      final res = validator.validate(decoded);
      if (!res.isValid) {
        log.error('manifest', 'rejected: ${res.errors.take(3).join('; ')}');
        throw res.toException();
      }
      final manifest = res.manifest!;
      if (cached != null &&
          !config.allowManifestDowngrade &&
          compareVersionStrings(manifest.releaseVersion, cached.manifest.releaseVersion) < 0) {
        throw FdamException(FdamErrorCode.versionConflict,
            'manifest ${manifest.releaseVersion} is older than cached ${cached.manifest.releaseVersion}');
      }
      final now = DateTime.now();
      await _writeCache((decoded as Map).cast<String, dynamic>(), resp.headers.value(HttpHeaders.etagHeader),
          resp.headers.value(HttpHeaders.lastModifiedHeader), now);
      log.info('manifest', 'fetched release ${manifest.releaseVersion} (${manifest.assets.length} assets)');
      return ManifestResult(
        manifest: manifest,
        source: ManifestSource.network,
        fetchedAt: now,
        previousReleaseVersion: cached?.manifest.releaseVersion,
      );
    } on FdamException catch (e) {
      final networkish = e.code == FdamErrorCode.networkUnavailable ||
          e.code == FdamErrorCode.downloadInterrupted ||
          (e.code == FdamErrorCode.httpError && e.retryable) ||
          e.code == FdamErrorCode.unknown;
      if (networkish && cached != null) {
        log.warn('manifest', 'offline, using cache: ${e.code.wireName}');
        return ManifestResult(
          manifest: cached.manifest,
          source: ManifestSource.cache,
          fetchedAt: cached.fetchedAt,
          previousReleaseVersion: cached.manifest.releaseVersion,
          networkError: e,
        );
      }
      rethrow;
    }
  }
}
