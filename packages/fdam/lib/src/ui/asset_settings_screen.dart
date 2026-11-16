// Screen 4: Asset Settings.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../asset_manager.dart';
import 'fdam_strings.dart';
import 'providers.dart';
import 'widgets.dart';

class AssetSettingsScreen extends ConsumerStatefulWidget {
  const AssetSettingsScreen({super.key});

  @override
  ConsumerState<AssetSettingsScreen> createState() => _AssetSettingsScreenState();
}

class _AssetSettingsScreenState extends ConsumerState<AssetSettingsScreen> {
  String? _message;
  bool _busy = false;

  Future<void> _run(Future<String?> Function() f) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final msg = await f();
      if (mounted) setState(() => _message = msg);
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(fdamStringsProvider);
    final snap = ref.watch(fdamSnapshotProvider);
    final m = ref.read(assetManagerProvider);
    final disabled = snap.phase == FdamPhase.disabled;

    return Scaffold(
      appBar: AppBar(title: Text(s.settingsTitle)),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (disabled) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(s.notConfigured)),
          if (_message != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(_message!)),
          FdamSection(title: s.settingsTitle, children: [
            SwitchListTile(
              autofocus: true,
              contentPadding: EdgeInsets.zero,
              title: Text(s.autoUpdate),
              subtitle: Text(s.autoUpdateDesc),
              value: snap.autoUpdate,
              onChanged: disabled ? null : (v) => m.setAutoUpdate(v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.wifiOnly),
              subtitle: Text(s.wifiOnlyDesc),
              value: snap.wifiOnly,
              onChanged: disabled ? null : (v) => m.setWifiOnly(v),
            ),
          ]),
          FdamSection(title: s.manualUpdate, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: disabled || _busy
                    ? null
                    : () => _run(() async {
                          final r = await m.checkForUpdates(autoDownload: false);
                          if (r.error != null) return r.error!.userMessage(s.lang);
                          final n = r.plan?.downloads.length ?? 0;
                          return n == 0 ? s.upToDate : s.updatesAvailable(n);
                        }),
                icon: const Icon(Icons.refresh),
                label: Text(s.checkUpdates),
              ),
              OutlinedButton.icon(
                onPressed: disabled || _busy
                    ? null
                    : () => _run(() async {
                          final r = await m.applyUpdates();
                          return r.allOk ? s.done : r.failed.values.first.userMessage(s.lang);
                        }),
                icon: const Icon(Icons.system_update),
                label: Text(s.manualUpdate),
              ),
            ]),
          ]),
          FdamSection(title: s.storageManagement, children: [
            FdamKeyValue(s.storageUsed, formatBytes(snap.installedBytes)),
            FdamKeyValue(
                s.availableStorage, snap.storage == null ? s.unknown : formatBytes(snap.storage!.availableBytes)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: disabled || _busy ? null : () => _run(() async => s.cleared(await m.clearOptionalCache())),
                icon: const Icon(Icons.cleaning_services),
                label: Text(s.clearOptional),
              ),
              OutlinedButton.icon(
                onPressed:
                    disabled || _busy ? null : () => _run(() async => s.removedCount((await m.cleanupRemoved()).length)),
                icon: const Icon(Icons.delete_sweep),
                label: Text(s.cleanupRemoved),
              ),
            ]),
          ]),
        ]),
      ),
    );
  }
}
