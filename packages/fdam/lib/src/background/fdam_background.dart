// Background maintenance through Android WorkManager (workmanager plugin).
//
// Android decides when the work actually runs (Doze, battery, constraints),
// so nothing here promises an immediate download. While the app is open the
// foreground AssetManager does the work and the background task skips.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import '../asset_manager.dart';
import '../core/config.dart';
import '../storage/fdam_database.dart';
import '../storage/fdam_paths.dart';

const String kFdamPeriodicTask = 'fdam.periodic_maintenance';
const String kFdamRetryTask = 'fdam.retry_pending';

/// Builds the same [FdamConfig] the app uses. Must be a top-level or static
/// function so it is available in the background isolate.
typedef FdamConfigBuilder = FdamConfig Function();

class FdamBackground {
  FdamBackground._();

  /// Registers WorkManager with [dispatcher] (a top-level function annotated
  /// with `@pragma('vm:entry-point')` that calls [FdamBackground.dispatch]).
  static Future<void> register(
    void Function() dispatcher, {
    required FdamConfig config,
    bool wifiOnly = false,
  }) async {
    if (!Platform.isAndroid || !config.isEnabled) return;
    await Workmanager().initialize(dispatcher);
    await Workmanager().registerPeriodicTask(
      kFdamPeriodicTask,
      kFdamPeriodicTask,
      frequency: config.backgroundCheckInterval,
      constraints: Constraints(
        networkType: wifiOnly ? NetworkType.unmetered : NetworkType.connected,
        requiresStorageNotLow: true,
        requiresBatteryNotLow: true,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  }

  /// Schedules a one-off retry of failed/pending downloads when a network is
  /// available (e.g. after the app is closed with downloads unfinished).
  static Future<void> scheduleRetry({bool wifiOnly = false}) async {
    if (!Platform.isAndroid) return;
    await Workmanager().registerOneOffTask(
      kFdamRetryTask,
      kFdamRetryTask,
      initialDelay: const Duration(minutes: 1),
      constraints: Constraints(
        networkType: wifiOnly ? NetworkType.unmetered : NetworkType.connected,
        requiresStorageNotLow: true,
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 2),
    );
  }

  static Future<void> cancelAll() async {
    if (!Platform.isAndroid) return;
    await Workmanager().cancelByUniqueName(kFdamPeriodicTask);
    await Workmanager().cancelByUniqueName(kFdamRetryTask);
  }

  /// Body of the background dispatcher.
  static void dispatch(FdamConfigBuilder buildConfig) {
    Workmanager().executeTask((task, input) async {
      WidgetsFlutterBinding.ensureInitialized();
      return runMaintenance(buildConfig(), await getApplicationSupportDirectory());
    });
  }

  /// One maintenance pass: check the manifest, then download updates and
  /// pending downloads. Returns false to ask WorkManager to retry later.
  static Future<bool> runMaintenance(FdamConfig config, Directory supportDir) async {
    if (!config.isEnabled) return true;
    final root = AssetManager.defaultRoot(supportDir);
    final paths = FdamPaths(root);
    await paths.ensure();
    // Skip when the app is in the foreground (it does the work itself and
    // two writers on the same .part file must never happen).
    final db = await FdamDatabase.open(paths.databasePath);
    final beat = DateTime.tryParse(await db.getSetting(kForegroundHeartbeatKey) ?? '');
    if (beat != null && DateTime.now().toUtc().difference(beat) < const Duration(minutes: 3)) {
      return true;
    }
    AssetManager? m;
    try {
      m = await AssetManager.create(config: config, rootDirectory: root, database: db, isBackground: true);
      await m.prefs.reload();
      final res = await m.checkForUpdates(autoDownload: false);
      if (res.error != null && res.plan == null) return false;
      await m.resumePersistedDownloads();
      final plan = m.snapshot.plan;
      if (plan == null) return true;
      final items = plan.automatic(includeUpdates: m.prefs.autoUpdate).map((e) => e.item!).toList();
      final r = await m.downloadItems(items);
      return r.allOk;
    } catch (_) {
      return false;
    } finally {
      await m?.dispose();
      try {
        await db.close();
      } catch (_) {}
    }
  }
}
