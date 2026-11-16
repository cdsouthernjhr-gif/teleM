// Screen 3: Asset Dashboard.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../asset_manager.dart';
import '../manifest/models.dart';
import '../storage/fdam_database.dart';
import '../version/version_planner.dart';
import 'asset_settings_screen.dart';
import 'download_manager_screen.dart';
import 'fdam_strings.dart';
import 'providers.dart';
import 'widgets.dart';

class AssetDashboardScreen extends ConsumerWidget {
  const AssetDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(fdamStringsProvider);
    final lang = ref.watch(fdamLanguageProvider);
    final snap = ref.watch(fdamSnapshotProvider);
    final m = ref.read(assetManagerProvider);

    if (snap.phase == FdamPhase.disabled) {
      return Scaffold(
        appBar: AppBar(title: Text(s.dashboardTitle)),
        body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(s.notConfigured))),
      );
    }

    final installed = snap.records.where((r) => r.status == LocalAssetStatus.installed).length;
    final plan = snap.plan;
    final updates = plan?.entries.where((e) => e.action == AssetAction.update || e.action == AssetAction.repair).length ?? 0;

    return Scaffold(
      appBar: AppBar(title: Text(s.dashboardTitle), actions: [
        IconButton(
          tooltip: s.openDownloads,
          icon: const Icon(Icons.download),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DownloadManagerScreen())),
        ),
        IconButton(
          tooltip: s.openSettings,
          icon: const Icon(Icons.settings),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AssetSettingsScreen())),
        ),
      ]),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => m.checkForUpdates(),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            if (snap.error != null) ErrorBanner(message: snap.error!.userMessage(lang)),
            if (snap.manifestSource == null && snap.manifest != null || snap.isOffline)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(s.offlineCache)),
            FdamSection(title: s.dashboardTitle, children: [
              FdamKeyValue(s.totalAssets, '$installed / ${snap.manifest?.assets.length ?? 0}'),
              FdamKeyValue(s.storageUsed, formatBytes(snap.installedBytes)),
              FdamKeyValue(s.availableStorage,
                  snap.storage == null ? s.unknown : formatBytes(snap.storage!.availableBytes)),
              FdamKeyValue(s.manifestVersion, snap.manifest?.releaseVersion ?? '-'),
              FdamKeyValue(s.lastUpdate, snap.lastCheck == null ? '-' : _date(snap.lastCheck!)),
              const SizedBox(height: 8),
              Text(updates == 0 ? s.upToDate : s.updatesAvailable(updates)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(
                  autofocus: true,
                  onPressed: snap.phase == FdamPhase.checking ? null : () => m.checkForUpdates(),
                  icon: const Icon(Icons.refresh),
                  label: Text(s.checkUpdates),
                ),
                if (updates > 0)
                  OutlinedButton.icon(
                      onPressed: () => m.applyUpdates(), icon: const Icon(Icons.system_update), label: Text(s.manualUpdate)),
              ]),
            ]),
            FdamSection(title: s.assetStatus, children: [
              if (plan != null)
                for (final e in plan.entries) _AssetRow(entry: e),
            ]),
          ]),
        ),
      ),
    );
  }

  static String _date(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

class _AssetRow extends ConsumerWidget {
  const _AssetRow({required this.entry});
  final PlannedAsset entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(fdamStringsProvider);
    final snap = ref.watch(fdamSnapshotProvider);
    final m = ref.read(assetManagerProvider);
    final item = entry.item;
    final local = entry.local;
    final task = snap.tasks[entry.id];
    final status = switch (entry.action) {
      AssetAction.keep => s.status('installed'),
      AssetAction.update => '${s.status('update')} (${local?.version} → ${item?.version})',
      AssetAction.install => s.status('install'),
      AssetAction.repair => s.status('repair'),
      AssetAction.removed => s.status('removed'),
    };
    final prio = switch (item?.priority) {
      AssetPriority.required => s.required,
      AssetPriority.startup => s.startup,
      _ => s.optional,
    };
    final busy = task != null && task.status.isActive;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(item != null ? categoryIcon(item.category) : Icons.archive_outlined),
      title: Text(item?.name ?? local?.name ?? entry.id),
      subtitle: Text([
        status,
        prio,
        if (item != null) formatBytes(item.sizeBytes),
        if (busy) '${s.status(task.status.name)} ${(task.progress * 100).toStringAsFixed(0)}%',
      ].join(' • ')),
      trailing: Wrap(spacing: 4, children: [
        if (entry.needsDownload && !busy)
          IconButton(
            tooltip: s.download,
            icon: const Icon(Icons.download),
            onPressed: () => m.downloadItems([item!]),
          ),
        if (local?.backupPath != null && !busy)
          IconButton(tooltip: s.rollback, icon: const Icon(Icons.undo), onPressed: () => m.rollback(entry.id)),
      ]),
    );
  }
}
