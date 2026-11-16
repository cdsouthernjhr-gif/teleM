// Riverpod bindings. The host app overrides [assetManagerProvider].

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../asset_manager.dart';
import 'fdam_strings.dart';

/// Must be overridden in ProviderScope with the app's [AssetManager].
final assetManagerProvider = Provider<AssetManager>(
  (ref) => throw UnimplementedError('Override assetManagerProvider in ProviderScope'),
);

/// UI language: 'ms' (default) or 'en'. The host app can change it at run
/// time with `container.read(fdamLanguageProvider.notifier).set('en')`.
final fdamLanguageProvider = NotifierProvider<FdamLanguage, String>(FdamLanguage.new);

class FdamLanguage extends Notifier<String> {
  @override
  String build() => 'ms';

  void set(String lang) => state = lang == 'en' ? 'en' : 'ms';
}

final fdamStringsProvider = Provider<FdamStrings>((ref) => FdamStrings(ref.watch(fdamLanguageProvider)));

/// Live snapshot of the asset manager (real download progress).
final fdamSnapshotProvider = NotifierProvider<FdamSnapshotNotifier, FdamSnapshot>(FdamSnapshotNotifier.new);

class FdamSnapshotNotifier extends Notifier<FdamSnapshot> {
  @override
  FdamSnapshot build() {
    final m = ref.watch(assetManagerProvider);
    final StreamSubscription<FdamSnapshot> sub = m.snapshots.listen((s) => state = s);
    ref.onDispose(sub.cancel);
    return m.snapshot;
  }
}
