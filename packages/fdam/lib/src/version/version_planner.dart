// Compares the manifest with what is installed and decides what to do with
// each asset. Uses asset id + version + SHA-256 + size, and checks the
// installed files still exist.

import '../manifest/models.dart';
import '../storage/fdam_database.dart';

enum AssetAction {
  /// Not on the device yet.
  install,

  /// Installed, but the manifest has a different version / hash / size.
  update,

  /// Installed and identical.
  keep,

  /// Recorded as installed but the files are missing or damaged.
  repair,

  /// On the device but no longer in the manifest (files kept for now).
  removed,
}

class PlannedAsset {
  const PlannedAsset({required this.action, this.item, this.local, this.isDowngrade = false});

  final AssetAction action;

  /// Null only for [AssetAction.removed].
  final AssetItem? item;
  final LocalAssetRecord? local;
  final bool isDowngrade;

  String get id => item?.id ?? local!.id;
  bool get needsDownload =>
      action == AssetAction.install || action == AssetAction.update || action == AssetAction.repair;
  AssetPriority get priority => item?.priority ?? AssetPriority.optional;
}

class UpdatePlan {
  UpdatePlan(this.entries);

  final List<PlannedAsset> entries;

  Iterable<PlannedAsset> get downloads => entries.where((e) => e.needsDownload);

  /// Required assets that are not usable yet (installs + repairs). Required
  /// updates where an older version is still installed do NOT block the app.
  Iterable<PlannedAsset> get blockingRequired => entries.where((e) =>
      e.item != null &&
      e.item!.required &&
      (e.action == AssetAction.install || e.action == AssetAction.repair));

  Iterable<PlannedAsset> get removed => entries.where((e) => e.action == AssetAction.removed);

  bool get requiredReady => blockingRequired.isEmpty;

  int get blockingRequiredBytes => blockingRequired.fold(0, (s, e) => s + e.item!.sizeBytes);

  /// What should be downloaded automatically: missing required/startup
  /// assets, and updates or repairs of anything already installed.
  /// New optional assets are left for the user.
  List<PlannedAsset> automatic({bool includeUpdates = true}) {
    final list = entries.where((e) {
      if (!e.needsDownload || e.item == null) return false;
      final item = e.item!;
      if (e.action == AssetAction.install) {
        return item.priority != AssetPriority.optional && !(item.deprecated && !item.required);
      }
      return includeUpdates || item.required;
    }).toList()
      ..sort((a, b) => a.priority.level.compareTo(b.priority.level));
    return list;
  }

  List<PlannedAsset> get optionalNotInstalled => entries
      .where((e) => e.action == AssetAction.install && e.item!.priority == AssetPriority.optional && !e.item!.deprecated)
      .toList();
}

typedef InstalledCheck = Future<bool> Function(LocalAssetRecord record);

class VersionPlanner {
  const VersionPlanner();

  Future<UpdatePlan> plan(
    AssetManifest manifest,
    List<LocalAssetRecord> local, {
    required InstalledCheck filesPresent,
  }) async {
    final byId = {for (final r in local) r.id: r};
    final entries = <PlannedAsset>[];
    for (final item in manifest.assets) {
      final rec = byId.remove(item.id);
      if (rec == null || (rec.status != LocalAssetStatus.installed && rec.status != LocalAssetStatus.removed)) {
        entries.add(PlannedAsset(action: AssetAction.install, item: item, local: rec));
        continue;
      }
      final identical = rec.version == item.version && rec.sha256 == item.sha256.toLowerCase();
      if (!identical) {
        final lv = AssetVersion.tryParse(rec.version);
        final down = lv != null && item.parsedVersion < lv;
        entries.add(PlannedAsset(action: AssetAction.update, item: item, local: rec, isDowngrade: down));
        continue;
      }
      if (!await filesPresent(rec)) {
        entries.add(PlannedAsset(action: AssetAction.repair, item: item, local: rec));
        continue;
      }
      entries.add(PlannedAsset(action: AssetAction.keep, item: item, local: rec));
    }
    for (final rec in byId.values) {
      if (rec.status == LocalAssetStatus.installed || rec.status == LocalAssetStatus.removed) {
        entries.add(PlannedAsset(action: AssetAction.removed, local: rec));
      }
    }
    return UpdatePlan(entries);
  }
}
