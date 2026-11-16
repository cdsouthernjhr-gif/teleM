// Strict validation of manifest JSON before anything in it is trusted.

import '../core/config.dart';
import '../core/errors.dart';
import '../core/path_safety.dart';
import 'models.dart';

final RegExp kAssetIdPattern = RegExp(r'^[a-z0-9][a-z0-9_.-]{0,63}$');
final RegExp kSha256Pattern = RegExp(r'^[a-f0-9]{64}$');

class ManifestValidationResult {
  ManifestValidationResult(this.errors, this.manifest, {this.requiresNewerManager = false});
  final List<String> errors;
  final AssetManifest? manifest;

  /// The manifest is well-formed but needs a newer FDAM.
  final bool requiresNewerManager;
  bool get isValid => errors.isEmpty && manifest != null;

  FdamException toException() => FdamException(
        requiresNewerManager ? FdamErrorCode.versionConflict : FdamErrorCode.manifestInvalid,
        errors.take(5).join('; '),
      );
}

class ManifestValidator {
  ManifestValidator(this.config, {this.managerVersion = kFdamManagerVersion});

  final FdamConfig config;
  final String managerVersion;

  ManifestValidationResult validate(Object? json) {
    final errors = <String>[];
    if (json is! Map) {
      return ManifestValidationResult(['root: must be a JSON object'], null);
    }
    final root = json.cast<String, dynamic>();

    const known = {'schemaVersion', 'appId', 'releaseVersion', 'minimumManagerVersion', 'generatedAt', 'assets'};
    for (final k in known) {
      if (!root.containsKey(k)) errors.add('root: missing "$k"');
    }
    if (errors.isNotEmpty) return ManifestValidationResult(errors, null);

    final schema = root['schemaVersion'];
    if (schema is! int || !kSupportedManifestSchemas.contains(schema)) {
      errors.add('schemaVersion: unsupported value $schema');
    }
    final appId = root['appId'];
    if (appId is! String || appId != config.appId) {
      errors.add('appId: "$appId" does not match "${config.appId}"');
    }
    if (!AssetVersion.isValid(_str(root['releaseVersion']))) {
      errors.add('releaseVersion: not a semantic version');
    }
    var needsNewer = false;
    final minMgr = _str(root['minimumManagerVersion']);
    if (!AssetVersion.isValid(minMgr)) {
      errors.add('minimumManagerVersion: not a semantic version');
    } else if (AssetVersion.parse(minMgr!) > AssetVersion.parse(managerVersion)) {
      needsNewer = true;
      errors.add('minimumManagerVersion: $minMgr is newer than this manager ($managerVersion)');
    }
    final gen = _str(root['generatedAt']);
    if (gen == null || DateTime.tryParse(gen) == null) {
      errors.add('generatedAt: not an ISO-8601 date');
    }

    final assets = root['assets'];
    if (assets is! List) {
      errors.add('assets: must be a list');
      return ManifestValidationResult(errors, null, requiresNewerManager: needsNewer);
    }

    final ids = <String>{};
    final paths = <String>{};
    final installPaths = <String>{};
    for (var i = 0; i < assets.length; i++) {
      final raw = assets[i];
      final where = 'assets[$i]';
      if (raw is! Map) {
        errors.add('$where: must be an object');
        continue;
      }
      final a = raw.cast<String, dynamic>();
      final id = a['id'];
      final label = id is String ? '$where ($id)' : where;
      if (id is! String || !kAssetIdPattern.hasMatch(id)) {
        errors.add('$label.id: must match ${kAssetIdPattern.pattern}');
      } else if (!ids.add(id)) {
        errors.add('$label.id: duplicate id');
      }
      final name = a['name'];
      if (name is! String || !isSafeFileName(name)) {
        errors.add('$label.name: must be a plain file name');
      }
      final cat = AssetCategory.tryParse(_str(a['category']));
      if (cat == null) errors.add('$label.category: unknown category "${a['category']}"');
      if (!AssetVersion.isValid(_str(a['version']))) {
        errors.add('$label.version: not a semantic version');
      }
      final url = a['url'];
      if (url is! String) {
        errors.add('$label.url: missing');
      } else {
        final problem = config.urlProblem(url, checkPrefixes: true);
        if (problem != null) errors.add('$label.url: $problem');
      }
      final lp = a['localPath'];
      if (lp is! String) {
        errors.add('$label.localPath: missing');
      } else {
        final problem = relativePathProblem(lp);
        if (problem != null || lp.endsWith('/')) {
          errors.add('$label.localPath: unsafe path (${problem ?? 'trailing_slash'})');
        } else if (!paths.add('${cat?.installRoot}/$lp'.toLowerCase())) {
          errors.add('$label.localPath: duplicate path');
        }
      }
      final size = a['sizeBytes'];
      if (size is! int || size <= 0) {
        errors.add('$label.sizeBytes: must be a positive integer');
      } else if (config.maxAssetSizeBytes != null && size > config.maxAssetSizeBytes!) {
        errors.add('$label.sizeBytes: larger than the configured limit');
      }
      final ext = a['extractedSizeBytes'];
      if (ext != null && (ext is! int || ext < 0)) {
        errors.add('$label.extractedSizeBytes: must be a non-negative integer');
      }
      final sha = a['sha256'];
      if (sha is! String || !kSha256Pattern.hasMatch(sha.toLowerCase())) {
        errors.add('$label.sha256: must be 64 hex characters');
      }
      for (final f in ['required', 'downloadOnStartup', 'extract', 'deprecated']) {
        if (a.containsKey(f) && a[f] is! bool) errors.add('$label.$f: must be true/false');
      }
      if (a['extract'] == true && !(name is String && name.toLowerCase().endsWith('.zip'))) {
        errors.add('$label.extract: only .zip files can be extracted');
      }
      if (a['extract'] == true && lp is String && !lp.toLowerCase().endsWith('.zip')) {
        errors.add('$label.localPath: must end with .zip when extract is true');
      }
      if (cat != null && lp is String) {
        final item = _tryItem(a);
        if (item != null) {
          final ip = item.installRelativePath.toLowerCase();
          for (final other in installPaths) {
            if (ip == other || ip.startsWith('$other/') || other.startsWith('$ip/')) {
              errors.add('$label.localPath: overlaps another asset ($other)');
              break;
            }
          }
          installPaths.add(ip);
        }
      }
    }

    if (errors.isNotEmpty) return ManifestValidationResult(errors, null, requiresNewerManager: needsNewer);
    try {
      return ManifestValidationResult(const [], AssetManifest.fromJson(root));
    } catch (e) {
      return ManifestValidationResult(['root: $e'], null);
    }
  }

  static AssetItem? _tryItem(Map<String, dynamic> a) {
    try {
      return AssetItem.fromJson(a);
    } catch (_) {
      return null;
    }
  }

  static String? _str(Object? o) => o is String ? o : null;
}
