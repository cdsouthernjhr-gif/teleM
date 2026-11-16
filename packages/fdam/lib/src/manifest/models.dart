// Manifest and download models.

import '../core/errors.dart';
import '../core/version.dart';

export '../core/version.dart' show AssetVersion;

enum AssetCategory {
  audio('audio', 'assets/audio'),
  image('image', 'assets/images'),
  video('video', 'assets/videos'),
  database('database', 'databases'),
  resource('resource', 'assets/resources'),
  config('config', 'assets/config'),
  data('data', 'assets/data');

  const AssetCategory(this.wireName, this.storageDir);

  final String wireName;

  /// Conventional folder for this category (created at startup). Manifest
  /// `localPath` values usually start with the matching sub-folder, e.g.
  /// `audio/pack.zip`.
  final String storageDir;

  /// Root (relative to the FDAM root) that `localPath` is resolved against:
  /// `databases/` for databases, `assets/` for everything else.
  String get installRoot => this == AssetCategory.database ? 'databases' : 'assets';

  static const Map<String, AssetCategory> _aliases = {
    'audio': AssetCategory.audio,
    'image': AssetCategory.image,
    'images': AssetCategory.image,
    'video': AssetCategory.video,
    'videos': AssetCategory.video,
    'database': AssetCategory.database,
    'databases': AssetCategory.database,
    'resource': AssetCategory.resource,
    'resources': AssetCategory.resource,
    'config': AssetCategory.config,
    'data': AssetCategory.data,
  };

  static AssetCategory? tryParse(String? s) => s == null ? null : _aliases[s.trim().toLowerCase()];
}

/// 1 = required, 2 = needed at startup, 3 = optional.
enum AssetPriority {
  required(1),
  startup(2),
  optional(3);

  const AssetPriority(this.level);
  final int level;
}

class AssetItem {
  const AssetItem({
    required this.id,
    required this.name,
    required this.category,
    required this.version,
    required this.url,
    required this.localPath,
    required this.sizeBytes,
    required this.sha256,
    this.required = false,
    this.downloadOnStartup = false,
    this.extract = false,
    this.deprecated = false,
    this.extractedSizeBytes,
    this.description = '',
  });

  final String id;
  final String name;
  final AssetCategory category;
  final String version;
  final String url;
  final String localPath;
  final int sizeBytes;
  final String sha256;
  final bool required;
  final bool downloadOnStartup;
  final bool extract;
  final bool deprecated;

  /// Optional hint: total size after extraction (used for storage checks
  /// before the ZIP is downloaded).
  final int? extractedSizeBytes;
  final String description;

  AssetVersion get parsedVersion => AssetVersion.parse(version);

  AssetPriority get priority => required
      ? AssetPriority.required
      : downloadOnStartup
          ? AssetPriority.startup
          : AssetPriority.optional;

  /// Install location relative to the FDAM root: `assets/<localPath>` (or
  /// `databases/<localPath>`). For extracted ZIPs this is a directory named
  /// after the ZIP without `.zip`, e.g. `audio/audio.zip` ->
  /// `assets/audio/audio/`.
  String get installRelativePath {
    final rel = extract && localPath.toLowerCase().endsWith('.zip')
        ? localPath.substring(0, localPath.length - 4)
        : localPath;
    return '${category.installRoot}/$rel';
  }

  /// Space needed on disk once installed.
  int get installedSizeEstimate => extract ? (extractedSizeBytes ?? sizeBytes * 3) : sizeBytes;

  /// Assumes JSON already passed [ManifestValidator].
  factory AssetItem.fromJson(Map<String, dynamic> j) => AssetItem(
        id: j['id'] as String,
        name: j['name'] as String,
        category: AssetCategory.tryParse(j['category'] as String?)!,
        version: (j['version'] as String).trim(),
        url: (j['url'] as String).trim(),
        localPath: j['localPath'] as String,
        sizeBytes: (j['sizeBytes'] as num).toInt(),
        sha256: (j['sha256'] as String).toLowerCase(),
        required: j['required'] == true,
        downloadOnStartup: j['downloadOnStartup'] == true,
        extract: j['extract'] == true,
        deprecated: j['deprecated'] == true,
        extractedSizeBytes: (j['extractedSizeBytes'] as num?)?.toInt(),
        description: (j['description'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category.wireName,
        'version': version,
        'url': url,
        'localPath': localPath,
        'sizeBytes': sizeBytes,
        'sha256': sha256,
        'required': required,
        'downloadOnStartup': downloadOnStartup,
        'extract': extract,
        if (deprecated) 'deprecated': true,
        if (extractedSizeBytes != null) 'extractedSizeBytes': extractedSizeBytes,
        if (description.isNotEmpty) 'description': description,
      };
}

class AssetManifest {
  const AssetManifest({
    required this.schemaVersion,
    required this.appId,
    required this.releaseVersion,
    required this.minimumManagerVersion,
    required this.generatedAt,
    required this.assets,
  });

  final int schemaVersion;
  final String appId;
  final String releaseVersion;
  final String minimumManagerVersion;
  final DateTime generatedAt;
  final List<AssetItem> assets;

  AssetItem? byId(String id) {
    for (final a in assets) {
      if (a.id == id) return a;
    }
    return null;
  }

  int get totalRequiredBytes => assets.where((a) => a.required).fold(0, (s, a) => s + a.sizeBytes);

  factory AssetManifest.fromJson(Map<String, dynamic> j) => AssetManifest(
        schemaVersion: (j['schemaVersion'] as num).toInt(),
        appId: j['appId'] as String,
        releaseVersion: j['releaseVersion'] as String,
        minimumManagerVersion: j['minimumManagerVersion'] as String,
        generatedAt: DateTime.parse(j['generatedAt'] as String),
        assets: [for (final a in j['assets'] as List) AssetItem.fromJson((a as Map).cast<String, dynamic>())],
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'appId': appId,
        'releaseVersion': releaseVersion,
        'minimumManagerVersion': minimumManagerVersion,
        'generatedAt': generatedAt.toUtc().toIso8601String(),
        'assets': [for (final a in assets) a.toJson()],
      };
}

enum DownloadStatus {
  queued,
  waitingForNetwork,
  downloading,
  paused,
  verifying,
  extracting,
  installing,
  completed,
  failed,
  cancelled;

  bool get isActive =>
      this == queued ||
      this == waitingForNetwork ||
      this == downloading ||
      this == verifying ||
      this == extracting ||
      this == installing;

  bool get isTerminal => this == completed || this == failed || this == cancelled;

  static DownloadStatus fromName(String? s) =>
      DownloadStatus.values.firstWhere((e) => e.name == s, orElse: () => DownloadStatus.failed);
}

/// Immutable snapshot of one download, emitted by the engine and shown by
/// the UI. All numbers are real (taken from bytes written to disk).
class DownloadTask {
  const DownloadTask({
    required this.assetId,
    required this.assetName,
    required this.category,
    required this.version,
    required this.url,
    required this.temporaryPath,
    required this.totalBytes,
    required this.priority,
    this.downloadedBytes = 0,
    this.status = DownloadStatus.queued,
    this.retryCount = 0,
    this.lastError,
    this.lastErrorDetail,
    this.bytesPerSecond = 0,
    this.extractProgress,
  });

  final String assetId;
  final String assetName;
  final AssetCategory category;
  final String version;
  final String url;
  final String temporaryPath;
  final int totalBytes;
  final AssetPriority priority;
  final int downloadedBytes;
  final DownloadStatus status;
  final int retryCount;
  final FdamErrorCode? lastError;
  final String? lastErrorDetail;
  final double bytesPerSecond;

  /// 0..1 while extracting.
  final double? extractProgress;

  double get progress => totalBytes <= 0 ? 0 : (downloadedBytes / totalBytes).clamp(0.0, 1.0);
  int get remainingBytes => (totalBytes - downloadedBytes).clamp(0, totalBytes);

  Duration? get eta {
    if (bytesPerSecond <= 1 || status != DownloadStatus.downloading) return null;
    return Duration(seconds: (remainingBytes / bytesPerSecond).ceil());
  }

  DownloadTask copyWith({
    int? downloadedBytes,
    DownloadStatus? status,
    int? retryCount,
    FdamErrorCode? lastError,
    String? lastErrorDetail,
    bool clearError = false,
    double? bytesPerSecond,
    double? extractProgress,
  }) =>
      DownloadTask(
        assetId: assetId,
        assetName: assetName,
        category: category,
        version: version,
        url: url,
        temporaryPath: temporaryPath,
        totalBytes: totalBytes,
        priority: priority,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        status: status ?? this.status,
        retryCount: retryCount ?? this.retryCount,
        lastError: clearError ? null : (lastError ?? this.lastError),
        lastErrorDetail: clearError ? null : (lastErrorDetail ?? this.lastErrorDetail),
        bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
        extractProgress: extractProgress ?? this.extractProgress,
      );
}
