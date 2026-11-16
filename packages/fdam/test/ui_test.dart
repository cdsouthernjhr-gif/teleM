import 'dart:io';

import 'package:fdam/fdam.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_env.dart';

Widget app(AssetManager m, Widget child) => ProviderScope(
      overrides: [assetManagerProvider.overrideWithValue(m)],
      child: MaterialApp(home: child),
    );

/// Pumps until [cond] is true, letting real I/O run between frames.
Future<void> pumpUntil(WidgetTester tester, bool Function() cond, {int maxSteps = 200}) async {
  for (var i = 0; i < maxSteps && !cond(); i++) {
    // Real time for I/O, fake time for timers created from the test zone.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(cond(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Widget tests replace HttpClient with a fake that answers 400; FDAM is
  // tested against a real local server instead.
  HttpOverrides.global = null;

  late TestEnv env;
  late AssetManager m;

  final req = TestAsset('images', 'logo.png', 'image', randomBytes(30000), required: true, localPath: 'images/logo.png');
  final opt = TestAsset('video', 'intro.mp4', 'video', randomBytes(20000, seed: 2), localPath: 'videos/intro.mp4');

  Future<void> setUpEnv(WidgetTester tester) async {
    await tester.runAsync(() async {
      env = await TestEnv.create();
      env.publish([req, opt]);
      m = await env.manager();
      await m.checkForUpdates();
    });
  }

  Future<void> tearDownEnv(WidgetTester tester) async {
    await tester.runAsync(() => env.dispose());
  }

  testWidgets('gate: setup screen -> real download -> app', (tester) async {
    await setUpEnv(tester);
    await tester.pumpWidget(app(m, const FdamGate(checkOnStart: false, child: Text('HOME'))));
    await tester.pump();
    expect(find.text('HOME'), findsNothing);
    expect(find.text('Persediaan Aset'), findsWidgets);
    expect(find.textContaining('Saiz muat turun wajib'), findsOneWidget);
    expect(find.text(formatBytes(30000)), findsWidgets);
    expect(find.text('Langkau muat turun pilihan'), findsOneWidget);

    await tester.tap(find.textContaining('Muat turun sekarang'));
    await pumpUntil(tester, () => find.text('HOME').evaluate().isNotEmpty);
    expect(m.snapshot.requiredReady, isTrue);
    // Optional asset was skipped.
    await tester.runAsync(() async => expect(await m.repository.isAssetDownloaded('video'), isFalse));
    await tearDownEnv(tester);
  });

  testWidgets('dashboard and download manager show real state; settings persist', (tester) async {
    await setUpEnv(tester);
    await tester.runAsync(() => m.downloadRequired());
    await tester.pumpWidget(app(m, const AssetDashboardScreen()));
    await tester.pump();
    expect(find.text('Papan Pemuka Aset'), findsWidgets);
    expect(find.text('1.0.0'), findsOneWidget); // manifest version
    expect(find.text('1 / 2'), findsOneWidget); // installed / total
    expect(find.textContaining('Dipasang'), findsOneWidget);
    expect(find.textContaining('Belum dimuat turun'), findsOneWidget);

    // Download the optional asset from the dashboard row.
    await tester.tap(find.byTooltip('Muat turun').first);
    await pumpUntil(tester, () => m.snapshot.records.length == 2);
    await tester.pump();
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Buka pengurus muat turun'));
    await tester.pumpAndSettle();
    expect(find.text('Pengurus Muat Turun'), findsOneWidget);
    expect(find.text('intro.mp4'), findsOneWidget);
    expect(find.textContaining('Selesai'), findsWidgets);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Tetapan aset'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi sahaja'), findsOneWidget);
    await tester.tap(find.text('Wi-Fi sahaja'));
    await tester.pump();
    expect(env.prefs.wifiOnly, isTrue);
    await tearDownEnv(tester);
  });

  testWidgets('disabled FDAM: gate lets the app through, dashboard explains', (tester) async {
    late AssetManager d;
    await tester.runAsync(() async {
      env = await TestEnv.create();
      d = await AssetManager.create(
        config: const FdamConfig(manifestUrl: '', appId: kTestAppId),
        rootDirectory: env.root,
        database: await env.db(),
        network: env.network,
        preferences: env.prefs,
        storage: env.storage,
        logger: FdamLogger(echo: false),
      );
    });
    await tester.pumpWidget(app(d, const FdamGate(child: Text('HOME'))));
    await tester.pump();
    expect(find.text('HOME'), findsOneWidget);
    await tester.pumpWidget(app(d, const AssetDashboardScreen()));
    await tester.pump();
    expect(find.textContaining('belum dikonfigurasi'), findsOneWidget);
    await tester.runAsync(() async {
      await d.dispose();
      await env.dispose();
    });
  });
}
