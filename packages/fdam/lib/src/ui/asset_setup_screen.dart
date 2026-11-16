// Screen 1: Asset Setup (first launch / missing required assets).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../asset_manager.dart';
import '../manifest/models.dart';
import 'download_manager_screen.dart';
import 'fdam_strings.dart';
import 'providers.dart';
import 'widgets.dart';

class AssetSetupScreen extends ConsumerStatefulWidget {
  const AssetSetupScreen({super.key, this.logo, this.appName = '', this.onContinueWithoutAssets});

  final Widget? logo;
  final String appName;

  /// When set, a "continue" button is shown if the manifest cannot be loaded
  /// at all (no cache, no network).
  final VoidCallback? onContinueWithoutAssets;

  @override
  ConsumerState<AssetSetupScreen> createState() => _AssetSetupScreenState();
}

class _AssetSetupScreenState extends ConsumerState<AssetSetupScreen> {
  bool _skipOptional = true;
  bool _busy = false;

  Future<void> _download() async {
    final m = ref.read(assetManagerProvider);
    setState(() => _busy = true);
    try {
      await m.downloadRequired();
      if (!_skipOptional) {
        final ids = m.snapshot.plan?.optionalNotInstalled.map((e) => e.id).toList() ?? const [];
        if (ids.isNotEmpty) await m.downloadOptional(ids);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      await ref.read(assetManagerProvider).checkForUpdates();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(fdamStringsProvider);
    final lang = ref.watch(fdamLanguageProvider);
    final snap = ref.watch(fdamSnapshotProvider);
    final plan = snap.plan;
    final requiredBytes = plan?.blockingRequiredBytes ?? 0;
    final optionalBytes = plan?.optionalNotInstalled.fold<int>(0, (v, e) => v + e.item!.sizeBytes) ?? 0;
    final downloading = snap.tasks.values.any((t) => t.status.isActive) || snap.installing.isNotEmpty;
    final noManifest = snap.manifest == null;
    final space = snap.storage?.availableBytes;
    final notEnough = space != null && requiredBytes > space;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(padding: const EdgeInsets.all(24), children: [
              if (widget.logo != null) Center(child: SizedBox(height: 96, child: widget.logo)),
              const SizedBox(height: 16),
              Text(
                widget.appName.isEmpty ? s.setupTitle : widget.appName,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(s.welcome, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              Center(child: NetworkChip(online: snap.network.internetReachable, s: s)),
              const SizedBox(height: 16),
              if (snap.error != null) ErrorBanner(message: snap.error!.userMessage(lang)),
              FdamSection(title: s.setupTitle, children: [
                FdamKeyValue(s.requiredSize, noManifest ? s.unknown : formatBytes(requiredBytes)),
                FdamKeyValue(s.availableStorage, space == null ? s.unknown : formatBytes(space)),
                if (plan != null)
                  for (final e in plan.blockingRequired)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(categoryIcon(e.item!.category)),
                      title: Text(e.item!.name),
                      subtitle: Text('${e.item!.category.wireName} • v${e.item!.version}'),
                      trailing: Text(formatBytes(e.item!.sizeBytes)),
                    ),
                if (optionalBytes > 0)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _skipOptional,
                    onChanged: _busy ? null : (v) => setState(() => _skipOptional = v ?? true),
                    title: Text(s.skipOptional),
                    subtitle: Text('${s.optional}: ${formatBytes(optionalBytes)}'),
                  ),
              ]),
              const SizedBox(height: 8),
              if (noManifest)
                FilledButton.icon(
                  autofocus: true,
                  onPressed: _busy || snap.phase == FdamPhase.checking ? null : _check,
                  icon: const Icon(Icons.refresh),
                  label: Text(s.retry),
                )
              else
                FilledButton.icon(
                  autofocus: true,
                  onPressed: _busy || downloading || notEnough ? null : _download,
                  icon: const Icon(Icons.download),
                  label: Text('${s.downloadNow} (${formatBytes(requiredBytes + (_skipOptional ? 0 : optionalBytes))})'),
                ),
              if (noManifest && widget.onContinueWithoutAssets != null) ...[
                const SizedBox(height: 8),
                OutlinedButton(onPressed: widget.onContinueWithoutAssets, child: Text(s.continueApp)),
              ],
              if (snap.tasks.isNotEmpty) ...[
                const SizedBox(height: 16),
                const DownloadList(shrinkWrap: true),
              ],
              if (snap.tasks.values.any((t) => t.status == DownloadStatus.failed))
                TextButton(onPressed: _busy ? null : _download, child: Text(s.retry)),
            ]),
          ),
        ),
      ),
    );
  }
}
