// Integration of the Flutter Dynamic Asset Manager (packages/fdam).
//
// FDAM stays disabled unless the build sets FDAM_MANIFEST_URL, so the TV
// app keeps working exactly as before without an assets repository.

import 'dart:async';
import 'dart:io';

import 'package:fdam/fdam.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants.dart';
import 'core/diagnostics.dart';

/// Same configuration in the UI isolate and in the WorkManager isolate.
FdamConfig buildFdamConfig() => const FdamConfig(
      manifestUrl: kFdamManifestUrl,
      appId: kFdamAppId,
      allowedUrlPrefixes: kFdamReleasePrefix == '' ? [] : [kFdamReleasePrefix],
      userAgent: 'MYASEANTV-FDAM/$kAppVersion (Android)',
    );

/// Entry point for background maintenance (Android WorkManager).
@pragma('vm:entry-point')
void fdamBackgroundDispatcher() => FdamBackground.dispatch(buildFdamConfig);

/// Holds the app's AssetManager and the Riverpod container used by the FDAM
/// screens. Null-safe: when FDAM is disabled no binding exists.
class FdamBinding {
  FdamBinding._(this.manager, this.container);

  final AssetManager manager;
  final ProviderContainer container;

  /// Creates the manager under `<support>/fdam`. Returns null when FDAM is
  /// not configured or cannot start (the app must keep working).
  static Future<FdamBinding?> init(Directory supportDir, {required String language}) async {
    final config = buildFdamConfig();
    if (!config.isEnabled) return null;
    try {
      final manager = await AssetManager.create(config: config, rootDirectory: AssetManager.defaultRoot(supportDir));
      final container = ProviderContainer(overrides: [assetManagerProvider.overrideWithValue(manager)]);
      container.read(fdamLanguageProvider.notifier).set(language);
      unawaited(FdamBackground.register(fdamBackgroundDispatcher, config: config, wifiOnly: manager.prefs.wifiOnly)
          .catchError((Object e) => diag.warn('fdam', 'background registration failed: $e')));
      return FdamBinding._(manager, container);
    } catch (e) {
      diag.error('fdam', 'start failed: $e');
      return null;
    }
  }

  /// For tests and for apps that build the manager themselves.
  factory FdamBinding.withManager(AssetManager manager, {String language = 'ms'}) {
    final container = ProviderContainer(overrides: [assetManagerProvider.overrideWithValue(manager)]);
    container.read(fdamLanguageProvider.notifier).set(language);
    return FdamBinding._(manager, container);
  }

  void setLanguage(String lang) => container.read(fdamLanguageProvider.notifier).set(lang);

  /// Wraps the MaterialApp so FDAM screens can be opened anywhere.
  Widget wrap(Widget app) => UncontrolledProviderScope(
        container: container,
        child: _FdamBindingScope(binding: this, child: app),
      );

  static FdamBinding? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FdamBindingScope>()?.binding;
}

class _FdamBindingScope extends InheritedWidget {
  const _FdamBindingScope({required this.binding, required super.child});
  final FdamBinding binding;
  @override
  bool updateShouldNotify(_FdamBindingScope old) => old.binding != binding;
}
