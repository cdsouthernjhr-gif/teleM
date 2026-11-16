// Orchestrator: manifest -> plan -> download -> verify -> install -> record.
// Framework-agnostic (no widgets); the Riverpod layer only observes it.

import 'dart:async';
import 'dart:io';

import 'core/config.dart';
import 'core/errors.dart';
import 'core/logger.dart';
import 'core/path_safety.dart';
import 'download/download_engine.dart';
import 'install/asset_installer.dart';
import 'integrity/hash_service.dart';
import 'manifest/manifest_reader.dart';
import 'manifest/models.dart';
import 'network/fdam_http.dart';
import 'network/network_monitor.dart';
import 'storage/asset_repository.dart';
import 'storage/fdam_database.dart';
import 'storage/fdam_paths.dart';
import 'storage/fdam_preferences.dart';
import 'storage/storage_info.dart';
import 'version/version_planner.dart';

enum FdamPhase {
  /// FDAM has no manifest URL configured.
  disabled,
  starting,
  checking,

  /// Required assets are missing; the app should show the setup screen.
  needsSetup,
  downloading,

  /// Required assets are present (optional ones may still be downloading).
  ready,

  /// Could not start (no cache, no network, invalid manifest...).
  error,
}

class FdamSnapshot {
  const FdamSnapshot({
    required this.phase,
    this.manifest,
    this.manifestSource,
    this.lastCheck,
    this.plan,
    this.tasks = const {},
    this.records = const [],
    this.network = const NetworkState(NetworkKind.other, null),
    this.error,
    this.storage,
    this.wifiOnly = false,
    this.autoUpdate = true,
    this.installing = const {},
  });

  final FdamPhase phase;
  final AssetManifest? manifest;
  final ManifestSource? manifestSource;
  final DateTime? lastCheck;
  final UpdatePlan? plan;
  final Map<String, DownloadTask> tasks;
  final List<LocalAssetRecord> records;
  final NetworkState network;
  final FdamException? error;
  final StorageSpace? storage;
  final bool wifiOnly;
  final bool autoUpdate;

  /// Asset id -> extraction progress (0..1) while installing.
  final Map<String, double> installing;

  bool get requiredReady => plan?.requiredReady ?? false;
  bool get isOffline => network.internetReachable == false;

  int get installedBytes => records
      .where((r) => r.status == LocalAssetStatus.installed || r.status == LocalAssetStatus.removed)
      .fold(0, (s, r) => s + r.sizeBytes);

  /// Overall progress of the current downloads, from real byte counts.
  ({int done, int total}) get overallBytes {
    var done = 0, total = 0;
    for (final t in tasks.values) {
      if (t.status == DownloadStatus.cancelled) continue;
      total += t.totalBytes;
      done += t.status == DownloadStatus.completed ? t.totalBytes : t.downloadedBytes;
    }
    return (done: done, total: total);
  }

  FdamSnapshot copyWith({
    FdamPhase? phase,
    AssetManifest? manifest,
    ManifestSource? manifestSource,
    DateTime? lastCheck,
    UpdatePlan? plan,
    Map<String, DownloadTask>? tasks,
    List<LocalAssetRecord>? records,
    NetworkState? network,
    FdamException? error,
    bool clearError = false,
    StorageSpace? storage,
    bool? wifiOnly,
    bool? autoUpdate,
    Map<String, double>? installing,
  }) =>
      FdamSnapshot(
        phase: phase ?? this.phase,
        manifest: manifest ?? this.manifest,
        manifestSource: manifestSource ?? this.manifestSource,
        lastCheck: lastCheck ?? this.lastCheck,
        plan: plan ?? this.plan,
        tasks: tasks ?? this.tasks,
        records: records ?? this.records,
        network: network ?? this.network,
        error: clearError ? null : (error ?? this.error),
        storage: storage ?? this.storage,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        autoUpdate: autoUpdate ?? this.autoUpdate,
        installing: installing ?? this.installing,
      );
}

class UpdateCheckResult {
  UpdateCheckResult(this.plan, this.source, {this.error});
  final UpdatePlan? plan;
  final ManifestSource? source;
  final FdamException? error;
}

class BatchResult {
  BatchResult(this.installed, this.failed);
  final List<String> installed;
  final Map<String, FdamException> failed;
  bool get allOk => failed.isEmpty;
}

class AssetManager {
  AssetManager._({
    required this.config,
    required this.paths,
    required this.db,
    required this.http,
    required this.network,
    required this.prefs,
    required this.storage,
    required this.log,
    required this.reader,
    required this.engine,
    required this.installer,
    required this.repository,
    required bool ownsNetwork,
    required this.isBackground,
  }) : _ownsNetwork = ownsNetwork;

  /// Conventional FDAM root inside the app's private support directory.
  static Directory defaultRoot(Directory supportDir) => Directory('${supportDir.path}/fdam');

  /// Creates and initializes a manager. Pass the optional parameters in
  /// tests or to share objects with the host app.
  static Future<AssetManager> create({
    required FdamConfig config,
    required Directory rootDirectory,
    FdamDatabase? database,
    FdamHttp? http,
    NetworkMonitor? network,
    FdamPreferences? preferences,
    StorageInfoProvider? storage,
    HashService hash = const HashService(),
    FdamLogger? logger,
    AssetUsageChecker? usageChecker,
    bool initialize = true,
    bool isBackground = false,
  }) async {
    final paths = FdamPaths(rootDirectory);
    await paths.ensure();
    final log = logger ?? FdamLogger(file: paths.logFile);
    final db = database ?? await FdamDatabase.open(paths.databasePath);
    final h = http ?? FdamHttp(config, logger: log);
    final ownsNetwork = network == null;
    final net = network ?? ConnectivityNetworkMonitor(config: config, http: h, logger: log);
    final prefs = preferences ?? await SharedFdamPreferences.load();
    final st = storage ?? const PlatformStorageInfo();
    final installer = AssetInstaller(config: config, paths: paths, db: db, storage: st, logger: log);
    final engine = DownloadEngine(
      config: config,
      http: h,
      db: db,
      paths: paths,
      network: net,
      hash: hash,
      wifiOnly: () => prefs.wifiOnly,
      logger: log,
    );
    final m = AssetManager._(
      config: config,
      paths: paths,
      db: db,
      http: h,
      network: net,
      prefs: prefs,
      storage: st,
      log: log,
      reader: ManifestReader(config: config, http: h, cacheFile: paths.manifestCache, logger: log),
      engine: engine,
      installer: installer,
      repository: AssetRepository(db: db, paths: paths, installer: installer, isInUse: usageChecker ?? assumeInUse),
      ownsNetwork: ownsNetwork,
      isBackground: isBackground,
    );
    if (initialize) await m.initialize();
    return m;
  }

  final FdamConfig config;
  final FdamPaths paths;
  final FdamDatabase db;
  final FdamHttp http;
  final NetworkMonitor network;
  final FdamPreferences prefs;
  final StorageInfoProvider storage;
  final FdamLogger log;
  final ManifestReader reader;
  final DownloadEngine engine;
  final AssetInstaller installer;
  final AssetRepository repository;
  final bool _ownsNetwork;

  /// True inside a WorkManager task (no foreground heartbeat).
  final bool isBackground;
  final VersionPlanner _planner = const VersionPlanner();

  final _snapshots = StreamController<FdamSnapshot>.broadcast();
  FdamSnapshot _snap = const FdamSnapshot(phase: FdamPhase.starting);
  final List<StreamSubscription<dynamic>> _subs = [];
  final Map<String, Future<void>> _inFlight = {};
  Future<void> _installLock = Future.value();
  Timer? _heartbeat;
  bool _initialized = false;
  bool _disposed = false;

  FdamSnapshot get snapshot => _snap;
  Stream<FdamSnapshot> get snapshots => _snapshots.stream;

  void _emit(FdamSnapshot s) {
    _snap = s;
    if (!_snapshots.isClosed) _snapshots.add(s);
  }

  // ---- lifecycle ------------------------------------------------------------

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _emit(_snap.copyWith(wifiOnly: prefs.wifiOnly, autoUpdate: prefs.autoUpdate));
    if (!config.isEnabled) {
      _emit(_snap.copyWith(phase: FdamPhase.disabled));
      return;
    }
    try {
      await installer.recover();
    } catch (e) {
      log.error('init', 'recovery failed: $e');
    }
    _subs.add(engine.updates.listen((t) {
      _emit(_snap.copyWith(tasks: engine.tasks));
    }));
    _subs.add(network.changes.listen((s) {
      _emit(_snap.copyWith(network: s));
      if (s.internetReachable == true) engine.nudge();
    }));
    if (!isBackground) {
      _heartbeat = Timer.periodic(const Duration(seconds: 60), (_) => _beat());
      unawaited(_beat());
    }

    // Offline-first: use the cached manifest immediately.
    final cached = await reader.readCache();
    if (cached != null) {
      await _replan(cached.manifest, ManifestSource.cache, cached.fetchedAt);
    } else {
      await _refreshRecords();
    }
    await _refreshStorage();
  }

  Future<void> _beat() async {
    try {
      await db.setSetting(kForegroundHeartbeatKey, DateTime.now().toUtc().toIso8601String());
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _heartbeat?.cancel();
    if (!isBackground) {
      try {
        await db.setSetting(kForegroundHeartbeatKey, null);
      } catch (_) {}
    }
    for (final s in _subs) {
      await s.cancel();
    }
    await engine.dispose();
    if (_ownsNetwork) network.dispose();
    await _snapshots.close();
    await log.flush();
  }

  // ---- manifest / plan ------------------------------------------------------

  /// Fetches the manifest (or uses the cache when offline), updates the plan
  /// and, when [autoDownload] is true and allowed, starts automatic
  /// downloads (required first, then startup assets and updates).
  Future<UpdateCheckResult> checkForUpdates({bool autoDownload = true}) async {
    if (!config.isEnabled) return UpdateCheckResult(null, null);
    final previousPhase = _snap.phase;
    _emit(_snap.copyWith(phase: FdamPhase.checking, clearError: true));
    final net = await network.refresh();
    _emit(_snap.copyWith(network: net));
    try {
      final res = await reader.fetch();
      await db.setSetting(kLastCheckKey, DateTime.now().toUtc().toIso8601String());
      final plan = await _replan(res.manifest, res.source, res.fetchedAt, error: res.networkError);
      if (autoDownload && res.networkError == null) {
        await resumePersistedDownloads();
        final auto = plan.automatic(includeUpdates: prefs.autoUpdate);
        final toStart = auto.where((e) => !(e.item!.required && e.action == AssetAction.install)).toList();
        // Missing required assets wait for the user on the setup screen,
        // unless setup was already done once (then they are repairs).
        if (toStart.isNotEmpty) unawaited(downloadItems(toStart.map((e) => e.item!).toList()));
      }
      return UpdateCheckResult(plan, res.source, error: res.networkError);
    } on FdamException catch (e) {
      log.error('check', '${e.code.wireName}: ${e.detail}');
      final hasPlan = _snap.plan != null;
      _emit(_snap.copyWith(
        phase: hasPlan ? _phaseFor(_snap.plan!) : (previousPhase == FdamPhase.ready ? FdamPhase.ready : FdamPhase.error),
        error: e,
      ));
      return UpdateCheckResult(_snap.plan, null, error: e);
    }
  }

  Future<UpdatePlan> _replan(AssetManifest manifest, ManifestSource source, DateTime fetchedAt,
      {FdamException? error}) async {
    try {
      await db.syncManifestFlags(manifest);
    } catch (e) {
      log.warn('plan', 'sync flags failed: $e');
    }
    final records = await db.allAssets();
    final skips = await db.settingsWithPrefix(kSkipPrefix);
    var plan = await _planner.plan(manifest, records, filesPresent: installer.filesPresent);
    // After a manual rollback, do not reinstall the exact version rolled back from.
    if (skips.isNotEmpty) {
      plan = UpdatePlan([
        for (final e in plan.entries)
          if (e.action == AssetAction.update && skips['$kSkipPrefix${e.id}'] == e.item!.sha256)
            PlannedAsset(action: AssetAction.keep, item: e.item, local: e.local)
          else
            e,
      ]);
    }
    final lastCheck = DateTime.tryParse(await db.getSetting(kLastCheckKey) ?? '');
    _emit(_snap.copyWith(
      manifest: manifest,
      manifestSource: source,
      lastCheck: lastCheck ?? fetchedAt,
      plan: plan,
      records: records,
      phase: _phaseFor(plan),
      error: error,
      clearError: error == null,
    ));
    return plan;
  }

  FdamPhase _phaseFor(UpdatePlan plan) {
    if (!plan.requiredReady) {
      final busy = plan.blockingRequired.any((e) => engine.isActive(e.id) || _inFlight.containsKey(e.id));
      return busy ? FdamPhase.downloading : FdamPhase.needsSetup;
    }
    return FdamPhase.ready;
  }

  Future<void> _refreshRecords() async {
    final records = await db.allAssets();
    _emit(_snap.copyWith(records: records));
  }

  Future<void> _refreshStorage() async {
    final s = await storage.spaceFor(paths.root.path);
    if (s != null) _emit(_snap.copyWith(storage: s));
  }

  Future<void> _replanCurrent() async {
    final m = _snap.manifest;
    if (m == null) {
      await _refreshRecords();
      return;
    }
    await _replan(m, _snap.manifestSource ?? ManifestSource.cache, _snap.lastCheck ?? DateTime.now(),
        error: _snap.error);
  }

  // ---- downloads ------------------------------------------------------------

  /// Re-queues downloads that were running when the app was closed.
  Future<void> resumePersistedDownloads() async {
    final m = _snap.manifest;
    if (m == null) return;
    for (final d in await db.allDownloads()) {
      final item = m.byId(d.assetId);
      if (item == null || item.sha256 != d.sha256) {
        await deletePath(d.temporaryPath);
        await db.deleteDownload(d.assetId);
        continue;
      }
      if (d.status == DownloadStatus.cancelled || d.status == DownloadStatus.completed) continue;
      if (engine.isActive(item.id) || _inFlight.containsKey(item.id)) continue;
      if (d.status == DownloadStatus.failed && d.retryCount >= config.maxRetries) continue;
      final part = File(d.temporaryPath);
      final have = await part.exists() ? await part.length() : 0;
      unawaited(downloadItems([item], paused: {
        if (d.status == DownloadStatus.paused) item.id: have,
      }));
    }
  }

  /// Downloads all missing required assets (the setup screen's button).
  Future<BatchResult> downloadRequired() async {
    final plan = _snap.plan;
    if (plan == null) {
      throw FdamException(FdamErrorCode.manifestNotFound, 'no manifest loaded');
    }
    final items = plan.downloads.where((e) => e.item!.required).map((e) => e.item!).toList();
    final r = await downloadItems(items);
    // Startup assets follow automatically without blocking.
    final startup = _snap.plan?.downloads.where((e) => e.item!.priority == AssetPriority.startup).map((e) => e.item!);
    if (startup != null && startup.isNotEmpty) unawaited(downloadItems(startup.toList()));
    return r;
  }

  Future<BatchResult> downloadOptional(Iterable<String> ids) {
    final m = _snap.manifest;
    if (m == null) return Future.value(BatchResult(const [], const {}));
    return downloadItems([for (final id in ids) ?m.byId(id)]);
  }

  /// Downloads all pending updates of installed assets and missing
  /// required/startup assets.
  Future<BatchResult> applyUpdates() async {
    final plan = _snap.plan;
    if (plan == null) return BatchResult(const [], const {});
    return downloadItems(plan.automatic(includeUpdates: true).map((e) => e.item!).toList());
  }

  /// Checks storage, downloads (priority order, limited concurrency),
  /// verifies and installs [items]. Never throws for a single asset failure;
  /// failures are returned in [BatchResult.failed].
  ///
  /// Ids in [paused] are queued in the paused state (value = bytes already
  /// on disk) and start when [resume] is called.
  Future<BatchResult> downloadItems(List<AssetItem> items, {Map<String, int> paused = const {}}) async {
    final installed = <String>[];
    final failed = <String, FdamException>{};
    final todo = <AssetItem>[];
    for (final i in items) {
      if (!todo.any((t) => t.id == i.id)) todo.add(i);
    }
    if (todo.isEmpty) return BatchResult(installed, failed);

    final space = await storage.spaceFor(paths.root.path);
    if (space != null) {
      var need = config.storageSafetyMarginBytes;
      for (final i in todo) {
        if (_inFlight.containsKey(i.id)) continue;
        final part = File(paths.partFile(i));
        final have = await part.exists() ? await part.length() : 0;
        need += (i.sizeBytes - have).clamp(0, i.sizeBytes) + (i.extract ? i.installedSizeEstimate : 0);
      }
      if (need > space.availableBytes) {
        final e = FdamException(FdamErrorCode.diskSpaceInsufficient,
            'need $need bytes, ${space.availableBytes} available');
        log.error('download', e.detail);
        for (final i in todo) {
          failed[i.id] = e;
        }
        _emit(_snap.copyWith(error: e, storage: space, phase: _snap.plan == null ? null : _phaseFor(_snap.plan!)));
        return BatchResult(installed, failed);
      }
    }

    final futures = <Future<void>>[];
    for (final item in todo) {
      final f = _inFlight[item.id] ??= _downloadAndInstall(item, paused: paused[item.id]).whenComplete(() {
        // Block body: returning the removed future would make it wait on itself.
        _inFlight.remove(item.id);
      });
      futures.add(f.then((_) => installed.add(item.id)).catchError((Object e) {
        failed[item.id] = e is FdamException ? e : FdamException(FdamErrorCode.unknown, '$e');
      }));
    }
    if (_snap.plan != null) _emit(_snap.copyWith(phase: _phaseFor(_snap.plan!)));
    await Future.wait(futures);
    await _replanCurrent();
    await _refreshStorage();
    if (failed.isNotEmpty) {
      final worst = failed.values.firstWhere((e) => e.code != FdamErrorCode.cancelled, orElse: () => failed.values.first);
      if (worst.code != FdamErrorCode.cancelled) _emit(_snap.copyWith(error: worst));
    }
    return BatchResult(installed, failed);
  }

  Future<void> _downloadAndInstall(AssetItem item, {int? paused}) async {
    final path = await engine.enqueue(item, startPaused: paused != null, initialBytes: paused ?? 0);
    // Serialize installs: extraction is disk-heavy.
    final prev = _installLock;
    final done = Completer<void>();
    _installLock = done.future;
    await prev;
    try {
      _emit(_snap.copyWith(installing: {..._snap.installing, item.id: 0}));
      await installer.install(item, path, onExtractProgress: (pr) {
        _emit(_snap.copyWith(installing: {..._snap.installing, item.id: pr.fraction}));
      });
    } catch (e) {
      // The verified file is not reusable after a failed install attempt.
      await deletePath(path);
      try {
        await db.deleteDownload(item.id);
      } catch (_) {}
      rethrow;
    } finally {
      final inst = {..._snap.installing}..remove(item.id);
      _emit(_snap.copyWith(installing: inst));
      done.complete();
    }
  }

  void pause(String id) => engine.pause(id);
  void resume(String id) => engine.resume(id);
  void cancel(String id) => engine.cancel(id);
  void pauseAll() => engine.pauseAll();
  void resumeAll() => engine.resumeAll();

  Future<BatchResult> retry(String id) {
    final item = _snap.manifest?.byId(id);
    if (item == null) return Future.value(BatchResult(const [], const {}));
    return downloadItems([item]);
  }

  // ---- maintenance ----------------------------------------------------------

  Future<void> rollback(String id) async {
    await installer.rollback(id);
    await _replanCurrent();
  }

  /// Deletes installed optional assets (never required ones).
  Future<int> clearOptionalCache() async {
    var n = 0;
    for (final r in await db.allAssets()) {
      if (r.required || r.priority != AssetPriority.optional.level) continue;
      if (engine.isActive(r.id)) continue;
      if (await repository.deleteAsset(r.id)) n++;
    }
    await _replanCurrent();
    await _refreshStorage();
    return n;
  }

  Future<List<String>> cleanupRemoved() async {
    final ids = await repository.cleanupRemoved();
    await _replanCurrent();
    await _refreshStorage();
    return ids;
  }

  Future<void> setWifiOnly(bool v) async {
    await prefs.setWifiOnly(v);
    _emit(_snap.copyWith(wifiOnly: v));
    engine.nudge();
  }

  Future<void> setAutoUpdate(bool v) async {
    await prefs.setAutoUpdate(v);
    _emit(_snap.copyWith(autoUpdate: v));
  }

  Future<void> refreshStorage() => _refreshStorage();

  // ---- convenience for the host app ----------------------------------------

  Future<String?> pathOf(String assetId) => repository.getAssetLocalPath(assetId);

  /// Absolute path of a file inside an extracted asset, or null.
  Future<File?> fileIn(String assetId, String relativePath) async {
    final dir = await pathOf(assetId);
    if (dir == null) return null;
    final full = safeJoin(dir, relativePath);
    if (full == null) return null;
    final f = File(full);
    return await f.exists() ? f : null;
  }
}

const String kForegroundHeartbeatKey = 'foreground_heartbeat';
const String kLastCheckKey = 'last_manifest_check';
