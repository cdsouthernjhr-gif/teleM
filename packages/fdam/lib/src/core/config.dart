// FDAM configuration. Everything that differs between apps lives here so the
// package can be reused without code changes.

import 'dart:io';

/// Version of this asset manager. A manifest can require a minimum version
/// through `minimumManagerVersion`.
const String kFdamManagerVersion = '1.0.0';

/// Supported manifest `schemaVersion` values.
const Set<int> kSupportedManifestSchemas = {1};

/// Hosts used by GitHub for releases, raw files and release redirects.
const List<String> kGitHubHosts = [
  'github.com',
  'raw.githubusercontent.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
  'codeload.github.com',
];

class FdamConfig {
  const FdamConfig({
    required this.manifestUrl,
    required this.appId,
    this.allowedHosts = kGitHubHosts,
    this.allowedUrlPrefixes = const [],
    this.insecureHttpHosts = const {},
    this.maxConcurrentDownloads = 2,
    this.maxRetries = 4,
    this.retryBaseDelay = const Duration(seconds: 2),
    this.retryMaxDelay = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
    this.maxRedirects = 5,
    this.maxManifestBytes = 5 * 1024 * 1024,
    this.maxAssetSizeBytes,
    this.storageSafetyMarginBytes = 50 * 1024 * 1024,
    this.zipLimits = const ZipLimits(),
    this.allowManifestDowngrade = false,
    this.keepBackups = true,
    this.backgroundCheckInterval = const Duration(hours: 12),
    this.userAgent = 'FDAM/$kFdamManagerVersion (Android)',
    this.httpClientFactory,
    this.connectivityProbeUrl,
  });

  /// Raw URL of manifest.json, e.g.
  /// https://raw.githubusercontent.com/OWNER/REPO/main/manifest/manifest.json
  /// Empty disables FDAM (the host app then runs as if no assets exist).
  final String manifestUrl;

  /// Must equal `appId` in the manifest.
  final String appId;

  /// Hosts allowed for the manifest, asset URLs and every redirect hop.
  /// A host matches itself and its sub-domains.
  final List<String> allowedHosts;

  /// Optional extra restriction for asset URLs, e.g.
  /// `https://github.com/OWNER/REPO/releases/download/`. Empty = any path on
  /// an allowed host.
  final List<String> allowedUrlPrefixes;

  /// Hosts where plain http is accepted. Only for local tests
  /// (`127.0.0.1`). Keep empty in production.
  final Set<String> insecureHttpHosts;

  final int maxConcurrentDownloads;
  final int maxRetries;
  final Duration retryBaseDelay;
  final Duration retryMaxDelay;
  final Duration connectTimeout;

  /// Maximum idle time between two received chunks.
  final Duration receiveTimeout;
  final int maxRedirects;
  final int maxManifestBytes;

  /// Optional upper bound for a single asset; null = no fixed limit (real
  /// free space is always checked).
  final int? maxAssetSizeBytes;

  /// Space that must stay free after a download/extraction.
  final int storageSafetyMarginBytes;
  final ZipLimits zipLimits;

  /// When false a manifest with an older `releaseVersion` than the cached
  /// one is rejected (protects against replaying an old manifest).
  final bool allowManifestDowngrade;

  /// Keep the previous version of each asset for rollback.
  final bool keepBackups;
  final Duration backgroundCheckInterval;
  final String userAgent;

  /// Lets the host app supply its own [HttpClient] (custom trust store etc.).
  final HttpClient Function()? httpClientFactory;

  /// URL used to prove the internet really works. Defaults to [manifestUrl].
  final String? connectivityProbeUrl;

  bool get isEnabled => manifestUrl.trim().isNotEmpty;

  String get probeUrl => connectivityProbeUrl ?? manifestUrl;

  /// Null when [url] may be fetched, otherwise a reason.
  String? urlProblem(String url, {bool checkPrefixes = false}) {
    final u = Uri.tryParse(url.trim());
    if (u == null || !u.hasScheme || u.host.isEmpty) return 'malformed';
    if (u.userInfo.isNotEmpty) return 'credentials_in_url';
    final host = u.host.toLowerCase();
    if (u.scheme == 'http') {
      if (!insecureHttpHosts.contains(host)) return 'not_https';
    } else if (u.scheme != 'https') {
      return 'bad_scheme';
    }
    if (u.fragment.isNotEmpty) return 'fragment';
    final hostOk = insecureHttpHosts.contains(host) ||
        allowedHosts.any((d) => host == d.toLowerCase() || host.endsWith('.${d.toLowerCase()}'));
    if (!hostOk) return 'host_not_allowed';
    if (checkPrefixes && allowedUrlPrefixes.isNotEmpty && !allowedUrlPrefixes.any(url.startsWith)) {
      return 'prefix_not_allowed';
    }
    return null;
  }
}

/// Limits that protect against ZIP bombs and abuse.
class ZipLimits {
  const ZipLimits({
    this.maxEntries = 20000,
    this.maxTotalUncompressedBytes = 8 * 1024 * 1024 * 1024,
    this.maxCompressionRatio = 200,
    this.allowSymlinks = false,
  });

  final int maxEntries;
  final int maxTotalUncompressedBytes;

  /// Uncompressed / compressed size, per entry and for the whole archive.
  final double maxCompressionRatio;
  final bool allowSymlinks;
}
