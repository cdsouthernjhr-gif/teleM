// Shared widgets for FDAM screens.

import 'package:flutter/material.dart';

import '../manifest/models.dart';
import 'fdam_strings.dart';

class FdamSection extends StatelessWidget {
  const FdamSection({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ...children,
        ]),
      ),
    );
  }
}

class FdamKeyValue extends StatelessWidget {
  const FdamKeyValue(this.k, this.v, {super.key});
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: Theme.of(context).textTheme.bodyMedium)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(v,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ]),
      );
}

IconData categoryIcon(AssetCategory c) => switch (c) {
      AssetCategory.audio => Icons.music_note,
      AssetCategory.image => Icons.image,
      AssetCategory.video => Icons.movie,
      AssetCategory.database => Icons.storage,
      AssetCategory.resource => Icons.folder_zip,
      AssetCategory.config => Icons.settings,
      AssetCategory.data => Icons.description,
    };

class NetworkChip extends StatelessWidget {
  const NetworkChip({super.key, required this.online, required this.s});
  final bool? online;
  final FdamStrings s;

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (online) {
      true => (s.online, Colors.green, Icons.wifi),
      false => (s.offline, Colors.orange, Icons.wifi_off),
      null => (s.checking, Colors.grey, Icons.sync),
    };
    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      label: Text('${s.internet}: $label'),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(message, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
      );
}
