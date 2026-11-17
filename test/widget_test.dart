import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_asean_tv/data/database_repository.dart';
import 'package:my_asean_tv/data/local_store.dart';
import 'package:my_asean_tv/main.dart';
import 'package:my_asean_tv/services/logo_cache.dart';
import 'package:my_asean_tv/state/app_state.dart';
import 'package:my_asean_tv/ui/player/player_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';
import 'services_test.dart' show FakeBackend;

Future<AppState> makeState(Map<String, Map<String, dynamic>> db, {bool online = true}) async {
  SharedPreferences.setMockInitialValues({});
  // The Android bridge does not exist in tests: answer like a phone (not TV, no VPN).
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('my_asean_tv/platform'), (call) async => call.method == 'openUrl' ? true : false);
  final store = await LocalStore.open();
  final client = MockClient((_) async => http.Response('', 404));
  final repo = DatabaseRepository(
    client: client,
    cache: MemoryCacheStore(),
    readAsset: (p) async => jsonEncode(db[p.split('/').last]),
    baseUrl: 'https://raw.githubusercontent.com/o/r/main/database/',
  );
  final state = AppState(
    client: client,
    repo: repo,
    store: store,
    logos: LogoCache(client: client, dir: Directory.systemTemp.createTempSync('logos'), repoRootUrl: repo.repoRootUrl),
    probe: () async => online,
    backgroundTasks: false,
  );
  await state.init();
  state.online = online;
  return state;
}

Future<void> pumpApp(WidgetTester t, AppState s) async {
  t.view.physicalSize = const Size(1920, 1080);
  t.view.devicePixelRatio = 1.5;
  addTearDown(t.view.reset);
  await t.pumpWidget(MyAseanTvApp(state: s));
  await t.pumpAndSettle();
}

Future<void> press(WidgetTester t, LogicalKeyboardKey k, {bool settle = true}) async {
  await t.sendKeyEvent(k);
  settle ? await t.pumpAndSettle() : await t.pump(const Duration(milliseconds: 300));
}

/// Android's BACK button reaches Flutter as a "pop route" request.
Future<void> back(WidgetTester t, {bool settle = true}) async {
  await t.binding.handlePopRoute();
  settle ? await t.pumpAndSettle() : await t.pump(const Duration(milliseconds: 500));
}

String? focusedCardId() {
  var e = FocusManager.instance.primaryFocus?.context;
  String? id;
  e?.visitAncestorElements((a) {
    final k = a.widget.key;
    if (k is ValueKey<String> && k.value.startsWith('card_')) {
      id = k.value.substring(5);
      return false;
    }
    return true;
  });
  return id;
}

void main() {
  testWidgets('home shows header, 4 countries, categories and Malaysian channels', (t) async {
    final s = await makeState(realDatabase());
    await pumpApp(t, s);
    expect(find.text('MY '), findsNothing); // rich text
    for (final c in ['Malaysia', 'Indonesia', 'Singapura', 'Brunei']) {
      expect(find.text(c), findsOneWidget);
    }
    for (final c in ['Semua', 'Berita', 'Hiburan', 'Sukan', 'Pendidikan', 'Kanak-kanak', 'Islamik', 'Dokumentari']) {
      expect(find.text(c), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('card_my_tv1')), findsOneWidget);
    expect(find.byKey(const ValueKey('card_my_awesome_tv')), findsOneWidget);
    expect(find.text('Dalam talian'), findsOneWidget);
  });

  testWidgets('every country and category can be selected', (t) async {
    final s = await makeState(realDatabase());
    await pumpApp(t, s);
    for (final country in s.bundle!.countries) {
      await t.tap(find.text(country.nameMs));
      await t.pumpAndSettle();
      expect(s.selectedCountry, country.code);
      for (final cat in s.bundle!.categories) {
        await t.tap(find.text(cat.nameMs));
        await t.pumpAndSettle();
        final expected = s.bundle!.channelsFor(country.code, category: cat.id);
        expect(s.visibleChannels.map((c) => c.id), playableFirst(expected).map((c) => c.id));
        // The grid is lazy: only the first card is guaranteed to be built.
        if (expected.isNotEmpty) {
          expect(find.byKey(ValueKey('card_${playableFirst(expected).first.id}')), findsOneWidget,
              reason: '${country.code}/${cat.id}');
        }
        if (expected.isEmpty) expect(find.text('Tiada saluran dalam kategori ini'), findsOneWidget);
      }
      await t.tap(find.text('Semua'));
      await t.pumpAndSettle();
    }
  });

  testWidgets('D-pad: first channel focused, arrows move focus, select opens player', (t) async {
    // Use a database where TV1 has no stream to exercise the official-platform path.
    final db = copyDb(realDatabase());
    // Remove all Malaysian streams so the grid keeps database order.
    for (final c in ((db['channels.json']!['countries'] as List).first as Map)['channels'] as List) {
      (c as Map)
        ..['stream_type'] = 'platform'
        ..['stream_url'] = ''
        ..['availability'] = 'unknown'
        ..['official_url'] = 'https://rtmklik.rtm.gov.my/';
    }
    final s = await makeState(db);
    await pumpApp(t, s);
    expect(focusedCardId(), 'my_tv1');
    await press(t, LogicalKeyboardKey.arrowRight);
    expect(focusedCardId(), 'my_tv2');
    await press(t, LogicalKeyboardKey.arrowLeft);
    expect(focusedCardId(), 'my_tv1');
    await press(t, LogicalKeyboardKey.select);
    expect(find.byType(PlayerScreen), findsOneWidget);
    // TV1 has no verified direct stream: explain and offer the official platform.
    expect(find.text('Saluran tidak dapat dimainkan'), findsOneWidget);
    expect(find.textContaining('Tiada stream terus yang disahkan'), findsOneWidget);
    expect(find.textContaining('BUKA PLATFORM RASMI'), findsOneWidget);
    await back(t);
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('offline: cached channel list and banner are shown', (t) async {
    final s = await makeState(realDatabase(), online: false);
    await pumpApp(t, s);
    expect(find.textContaining('Tiada sambungan internet'), findsOneWidget);
    expect(find.byKey(const ValueKey('card_my_tv1')), findsOneWidget);
    expect(find.text('Luar talian'), findsOneWidget);
  });

  testWidgets('player: plays a stream, channel up/down with remote, favourite, back', (t) async {
    final backend = FakeBackend();
    PlayerScreen.debugBackendFactory = () => backend;
    addTearDown(() => PlayerScreen.debugBackendFactory = null);
    final s = await makeState(playableDb());
    await pumpApp(t, s);
    await press(t, LogicalKeyboardKey.select, settle: false); // TV1
    expect(backend.opened.last, 'https://streams.example.com/tv1/master.m3u8');
    expect(find.text('Saluran tidak dapat dimainkan'), findsNothing);
    expect(s.store.lastChannel, 'my_tv1');

    // Let the overlay hide, then CH+ / arrow up zaps.
    await t.pump(const Duration(seconds: 6));
    await press(t, LogicalKeyboardKey.channelUp, settle: false);
    expect(backend.opened.last, 'https://streams.example.com/tv2/index.m3u8');
    await t.pump(const Duration(seconds: 6));
    await press(t, LogicalKeyboardKey.arrowDown, settle: false);
    expect(backend.opened.last, 'https://streams.example.com/tv1/master.m3u8');

    // OK shows controls, favourite button works.
    await t.pump(const Duration(seconds: 6));
    await press(t, LogicalKeyboardKey.select, settle: false);
    expect(find.byKey(const ValueKey('btn_fav')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('btn_fav')));
    await t.pump(const Duration(milliseconds: 300));
    expect(s.store.isFavourite('my_tv1'), isTrue);

    // Back with controls visible only hides them; second back leaves.
    await back(t, settle: false);
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('btn_fav')), findsNothing);
    await back(t, settle: false);
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.textContaining('Saluran terakhir'), findsOneWidget);
  });

  testWidgets('player: geo-restricted failure shows reason, official platform and alternatives', (t) async {
    final backend = FakeBackend()
      ..failUrls.addAll(['master.m3u8', 'index.m3u8'])
      ..failMessage = 'Source error: Response code: 451';
    PlayerScreen.debugBackendFactory = () => backend;
    addTearDown(() => PlayerScreen.debugBackendFactory = null);
    final s = await makeState(playableDb());
    await pumpApp(t, s);
    await press(t, LogicalKeyboardKey.select, settle: false);
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(seconds: 2));
    }
    expect(find.text('Saluran tidak dapat dimainkan'), findsOneWidget);
    expect(find.text('GEO_RESTRICTED'), findsWidgets);
    expect(find.textContaining('tidak tersedia di negara anda'), findsOneWidget);
    expect(find.byKey(const ValueKey('btn_official')), findsOneWidget);
    expect(find.byKey(const ValueKey('btn_retry')), findsOneWidget);
    // Bounded: primary + secondary, no infinite retries on a permanent error.
    expect(backend.opened.length, 2);
  });

  testWidgets('settings screen renders and language switch works', (t) async {
    final s = await makeState(realDatabase());
    await pumpApp(t, s);
    await t.tap(find.text('Tetapan'));
    await t.pumpAndSettle();
    expect(find.text('KEMAS KINI MANUAL'), findsOneWidget);
    expect(find.text('BUKA TETAPAN VPN ANDROID'), findsOneWidget);
    await t.tap(find.text('English'));
    await t.pumpAndSettle();
    expect(s.lang, 'en');
    expect(find.text('MANUAL UPDATE'), findsOneWidget);
  });
}
