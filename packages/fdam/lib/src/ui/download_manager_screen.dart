// Screen 2: Download Manager. All numbers come from bytes written to disk.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../manifest/models.dart';
import 'fdam_strings.dart';
import 'providers.dart';
import 'widgets.dart';

class DownloadManagerScreen extends ConsumerWidget {
  const DownloadManagerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(fdamStringsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(s.downloadsTitle)),
      body: const SafeArea(child: DownloadList(padding: EdgeInsets.all(16))),
    );
  }
}

/// Overall progress + one tile per download. Also used on the setup screen.
class DownloadList extends ConsumerWidget {
  const DownloadList({super.key, this.padding = EdgeInsets.zero, this.shrinkWrap = false});
  final EdgeInsets padding;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(fdamStringsProvider);
    final snap = ref.watch(fdamSnapshotProvider);
    final tasks = snap.tasks.values.toList()
      ..sort((a, b) {
        final p = a.priority.level.compareTo(b.priority.level);
        return p != 0 ? p : a.assetName.compareTo(b.assetName);
      });
    final overall = snap.overallBytes;
    final speed = tasks.fold<double>(0, (v, t) => v + (t.status == DownloadStatus.downloading ? t.bytesPerSecond : 0));
    return ListView(
      padding: padding,
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      children: [
        FdamSection(title: s.overall, children: [
          LinearProgressIndicator(value: overall.total == 0 ? 0 : overall.done / overall.total, minHeight: 8),
          const SizedBox(height: 8),
          Text('${formatBytes(overall.done)} / ${formatBytes(overall.total)}'
              '${speed > 0 ? '  •  ${formatBytes(speed)}/s' : ''}'),
          if (tasks.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: () => ref.read(assetManagerProvider).pauseAll(),
                  icon: const Icon(Icons.pause),
                  label: Text(s.pause)),
              OutlinedButton.icon(
                  onPressed: () => ref.read(assetManagerProvider).resumeAll(),
                  icon: const Icon(Icons.play_arrow),
                  label: Text(s.resume)),
            ]),
          ],
        ]),
        if (tasks.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(s.noDownloads)),
        for (final t in tasks) DownloadTile(task: t, extract: snap.installing[t.assetId]),
      ],
    );
  }
}

class DownloadTile extends ConsumerWidget {
  const DownloadTile({super.key, required this.task, this.extract});
  final DownloadTask task;
  final double? extract;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(fdamStringsProvider);
    final lang = ref.watch(fdamLanguageProvider);
    final m = ref.read(assetManagerProvider);
    final t = task;
    final installing = extract != null;
    final statusText = installing ? s.status('installing') : s.status(t.status.name);
    final eta = t.eta;
    final details = <String>[
      '${formatBytes(t.downloadedBytes)} / ${formatBytes(t.totalBytes)}',
      if (t.status == DownloadStatus.downloading && t.bytesPerSecond > 0) '${formatBytes(t.bytesPerSecond)}/s',
      if (t.status != DownloadStatus.completed) '${formatBytes(t.remainingBytes)} ${s.remaining}',
      if (eta != null) '~${formatDuration(eta)}',
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(categoryIcon(t.category)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(t.assetName, style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
            ),
            Text('${t.category.wireName} • v${t.version}', style: Theme.of(context).textTheme.bodySmall),
          ]),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: installing ? extract : (t.status == DownloadStatus.verifying ? null : t.progress),
            minHeight: 6,
          ),
          const SizedBox(height: 6),
          Text('$statusText  •  ${details.join('  •  ')}', style: Theme.of(context).textTheme.bodySmall),
          if (t.lastError != null && t.status != DownloadStatus.completed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(fdamErrorText(t, lang), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Wrap(spacing: 4, children: [
            if (t.status == DownloadStatus.downloading ||
                t.status == DownloadStatus.queued ||
                t.status == DownloadStatus.waitingForNetwork)
              TextButton.icon(onPressed: () => m.pause(t.assetId), icon: const Icon(Icons.pause), label: Text(s.pause)),
            if (t.status == DownloadStatus.paused)
              TextButton.icon(
                  onPressed: () => m.resume(t.assetId), icon: const Icon(Icons.play_arrow), label: Text(s.resume)),
            if (t.status == DownloadStatus.failed || t.status == DownloadStatus.cancelled)
              TextButton.icon(onPressed: () => m.retry(t.assetId), icon: const Icon(Icons.refresh), label: Text(s.retry)),
            if (!t.status.isTerminal && t.status != DownloadStatus.verifying && !installing)
              TextButton.icon(onPressed: () => m.cancel(t.assetId), icon: const Icon(Icons.close), label: Text(s.cancel)),
          ]),
        ]),
      ),
    );
  }
}

String fdamErrorText(DownloadTask t, String lang) {
  final code = t.lastError;
  if (code == null) return '';
  return '${fdamErrorMessage(code, lang)} (${code.wireName})';
}
