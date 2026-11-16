import 'dart:io';

import 'package:fdam/fdam.dart' show FdamGate;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/constants.dart';
import 'core/diagnostics.dart';
import 'core/http_client_factory.dart';
import 'data/database_repository.dart';
import 'data/local_store.dart';
import 'fdam_setup.dart';
import 'services/logo_cache.dart';
import 'state/app_state.dart';
import 'ui/home/home_screen.dart';
import 'ui/widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep image memory small for 2 GB TV boxes.
  PaintingBinding.instance.imageCache
    ..maximumSize = 150
    ..maximumSizeBytes = 24 << 20;

  FlutterError.onError = (d) {
    diag.error('flutter', d.exceptionAsString().split('\n').first);
    FlutterError.presentError(d);
  };
  PlatformDispatcher.instance.onError = (e, _) {
    diag.error('async', e.toString().split('\n').first);
    return true;
  };

  final client = await createHttpClient();
  final support = await getApplicationSupportDirectory();
  final store = await LocalStore.open();
  final repo = DatabaseRepository(
    client: client,
    cache: FileCacheStore(File('${support.path}/database_cache.json')),
    readAsset: rootBundle.loadString,
    baseUrl: kDatabaseBaseUrl,
    appBuild: kAppBuild,
  );
  final state = AppState(
    client: client,
    repo: repo,
    store: store,
    logos: LogoCache(client: client, dir: Directory('${support.path}/logos'), repoRootUrl: repo.repoRootUrl),
  );
  await state.init();
  // Extra assets (audio, images, video, databases) from GitHub Releases.
  // Disabled unless the build sets FDAM_MANIFEST_URL.
  final fdam = await FdamBinding.init(support, language: state.lang);
  if (fdam != null) state.addListener(() => fdam.setLanguage(state.lang));
  runApp(MyAseanTvApp(state: state, fdam: fdam));
}

class MyAseanTvApp extends StatelessWidget {
  const MyAseanTvApp({super.key, required this.state, this.fdam});
  final AppState state;

  /// Null when the dynamic asset manager is not configured.
  final FdamBinding? fdam;

  @override
  Widget build(BuildContext context) {
    final binding = fdam;
    final app = AppScope(
      state: state,
      child: MaterialApp(
        title: 'MY ASEAN TV',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: AppColors.bg,
          colorScheme: const ColorScheme.dark(primary: AppColors.accent, secondary: AppColors.accent2),
          useMaterial3: true,
          // Large, readable focus targets on TV.
          visualDensity: VisualDensity.standard,
        ),
        // Android TV remotes send DPAD_CENTER as "select".
        shortcuts: {
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        // Required extra assets (if any) are downloaded before the home
        // screen; without a manifest the app still opens.
        home: binding == null
            ? const HomeScreen()
            : const FdamGate(appName: 'MY ASEAN TV', allowContinueWithoutManifest: true, child: HomeScreen()),
      ),
    );
    return binding == null ? app : binding.wrap(app);
  }
}
