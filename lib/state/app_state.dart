// Application state shared by all screens.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' hide Category;
import 'package:http/http.dart' as http;

import '../core/diagnostics.dart';
import '../core/platform_bridge.dart';
import '../core/strings.dart';
import '../core/url_policy.dart';
import '../data/database_repository.dart';
import '../data/local_store.dart';
import '../data/models.dart';
import '../services/geo_service.dart';
import '../services/logo_cache.dart';
import '../services/stream_health_checker.dart';

typedef ConnectivityProbe = Future<bool> Function();

Future<bool> defaultConnectivityProbe() async {
  try {
    final r = await InternetAddress.lookup('raw.githubusercontent.com').timeout(const Duration(seconds: 4));
    return r.isNotEmpty && r.first.rawAddress.isNotEmpty;
  } catch (_) {
    return false;
  }
}

/// Channels with a direct stream first; database order is kept inside each
/// group (stable sort).
List<Channel> playableFirst(List<Channel> list) => [
      ...list.where((c) => c.hasDirectStream),
      ...list.where((c) => !c.hasDirectStream),
    ];

/// Pseudo "country" tab for favourites.
const String kFavouritesTab = 'FAV';

class AppState extends ChangeNotifier {
  AppState({
    required this.client,
    required this.repo,
    required this.store,
    required this.logos,
    this.bridge = const PlatformBridge(),
    this.probe = defaultConnectivityProbe,
    this.backgroundTasks = true,
  }) : geo = GeoService(client: client);

  final http.Client client;
  final DatabaseRepository repo;
  final LocalStore store;
  final LogoCache logos;
  final PlatformBridge bridge;
  final ConnectivityProbe probe;
  final GeoService geo;

  /// Disabled in widget tests to avoid periodic timers.
  final bool backgroundTasks;

  DatabaseBundle? bundle;
  bool online = true;
  bool vpnActive = false;
  bool isTv = false;
  bool updating = false;
  String? updateMessage;
  bool healthRunning = false;
  int healthDone = 0;
  int healthTotal = 0;
  String selectedCountry = 'MY';
  String selectedCategory = Category.all;
  Map<String, HealthResult> health = {};
  GeoInfo? geoInfo;
  Timer? _netTimer;

  S get s => S(store.language);
  String get lang => store.language;

  UrlPolicy get policy => UrlPolicy(
        streamDomains: bundle?.config.allowedStreamDomains ?? const [],
        officialDomains: bundle?.config.allowedOfficialDomains ?? const [],
      );

  StreamHealthChecker get checker => StreamHealthChecker(
        client: client,
        policy: policy,
        timeout: Duration(seconds: bundle?.config.healthTimeoutSeconds ?? 10),
      );

  Future<void> init() async {
    bundle = await repo.loadLocal();
    health = store.healthResults;
    geoInfo = store.geoInfo;
    final saved = store.selectedCountry;
    if (saved != null && (saved == kFavouritesTab || bundle!.country(saved) != null)) {
      selectedCountry = saved;
    } else if (bundle!.countries.isNotEmpty) {
      selectedCountry = bundle!.countries.first.code;
    }
    notifyListeners();
    isTv = await bridge.isTelevision();
    if (backgroundTasks) {
      unawaited(_refreshNetwork());
      _netTimer = Timer.periodic(const Duration(seconds: 20), (_) => _refreshNetwork());
      unawaited(_startupTasks());
    }
  }

  Future<void> _startupTasks() async {
    online = await probe();
    notifyListeners();
    if (!online) return;
    await update();
    if (store.geoEnabled) await detectCountry();
  }

  Future<void> _refreshNetwork() async {
    final wasOnline = online;
    final o = await probe();
    final v = await bridge.isVpnActive();
    if (o != online || v != vpnActive) {
      online = o;
      vpnActive = v;
      diag.info('net', 'online=$o vpn=$v');
      notifyListeners();
    }
    // Came back online: refresh the database quietly.
    if (!wasOnline && o && !updating) unawaited(update());
  }

  /// Automatic or manual (force) database update.
  Future<UpdateResult?> update({bool force = false}) async {
    if (updating) return null;
    updating = true;
    updateMessage = s.t('updating');
    notifyListeners();
    final r = await repo.checkForUpdate(force: force);
    updating = false;
    await store.setLastUpdateCheck(DateTime.now());
    switch (r.outcome) {
      case UpdateOutcome.updated:
        bundle = repo.current;
        updateMessage = '${s.t('updated_to')} ${bundle!.version}';
        break;
      case UpdateOutcome.upToDate:
        updateMessage = s.t('up_to_date');
        break;
      case UpdateOutcome.failedNetwork:
        updateMessage = s.t('update_failed');
        break;
      case UpdateOutcome.failedInvalid:
        updateMessage = s.t('update_invalid');
        break;
      case UpdateOutcome.appTooOld:
        updateMessage = s.t('app_too_old');
        break;
    }
    notifyListeners();
    return r;
  }

  String sourceLabel() => switch (repo.source) {
        DatabaseSource.remote => s.t('source_remote'),
        DatabaseSource.cache => s.t('source_cache'),
        DatabaseSource.bundled => s.t('source_bundled'),
        null => '-',
      };

  Future<void> detectCountry() async {
    final g = await geo.detect(bundle?.config.geoEndpoints ?? const []);
    if (g != null) {
      geoInfo = g;
      await store.setGeoInfo(g);
      notifyListeners();
    }
  }

  Future<void> setGeoEnabled(bool v) async {
    await store.setGeoEnabled(v);
    if (!v) {
      geoInfo = null;
      await store.setGeoInfo(null);
    }
    notifyListeners();
    if (v) await detectCountry();
  }

  Future<void> setLanguage(String l) async {
    await store.setLanguage(l);
    notifyListeners();
  }

  void selectCountry(String code) {
    selectedCountry = code;
    store.setSelectedCountry(code);
    notifyListeners();
  }

  void selectCategory(String id) {
    selectedCategory = id;
    notifyListeners();
  }

  List<Channel> get visibleChannels {
    final b = bundle;
    if (b == null) return const [];
    if (selectedCountry == kFavouritesTab) {
      final fav = store.favourites;
      return fav.map(b.byId).whereType<Channel>().where((c) => c.enabled).toList();
    }
    return playableFirst(b.channelsFor(selectedCountry, category: selectedCategory));
  }

  /// Channels used for channel up/down in the player.
  List<Channel> zapList(Channel current) {
    final b = bundle;
    if (b == null) return [current];
    if (selectedCountry == kFavouritesTab && store.isFavourite(current.id)) return visibleChannels;
    return playableFirst(b.channelsFor(current.countryCode));
  }

  /// Effective status: on-device test result if present, else database value.
  StreamStatus statusOf(Channel c) => health[c.id]?.status ?? c.availability;

  Channel? get lastChannel {
    final id = store.lastChannel;
    return id == null ? null : bundle?.byId(id);
  }

  Future<void> toggleFavourite(String id) async {
    await store.toggleFavourite(id);
    notifyListeners();
  }

  Future<void> recordPlaybackSuccess(Channel c) async {
    await store.addHistory(c.id);
    await store.recordSuccess(c.id);
    health[c.id] = HealthResult(StreamStatus.online, detail: 'played_on_device');
    await store.saveHealthResults(health);
    notifyListeners();
  }

  Future<void> recordHealth(String id, HealthResult r) async {
    health[id] = r;
    await store.saveHealthResults(health);
    notifyListeners();
  }

  Future<void> runHealthCheckAll() async {
    final b = bundle;
    if (b == null || healthRunning) return;
    final list = b.channels.where((c) => c.enabled && c.hasDirectStream).toList();
    healthRunning = true;
    healthDone = 0;
    healthTotal = list.length;
    notifyListeners();
    await checker.checkAll(list,
        userCountry: geoInfo?.countryCode,
        concurrency: b.config.healthMaxConcurrency, onResult: (id, r) {
      health[id] = r;
      healthDone++;
      notifyListeners();
    });
    await store.saveHealthResults(health);
    healthRunning = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _netTimer?.cancel();
    super.dispose();
  }
}
