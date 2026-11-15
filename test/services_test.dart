import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:my_asean_tv/core/diagnostics.dart';
import 'package:my_asean_tv/core/url_policy.dart';
import 'package:my_asean_tv/data/models.dart';
import 'package:my_asean_tv/services/geo_service.dart';
import 'package:my_asean_tv/services/playback_controller.dart';
import 'package:my_asean_tv/services/playback_plan.dart';
import 'package:my_asean_tv/services/stream_health_checker.dart';

import 'helpers.dart';

final policy = UrlPolicy(streamDomains: ['streams.example.com'], officialDomains: ['rtm.gov.my']);

const master = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nlow/index.m3u8\n';
const media = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6.0,\nseg001.ts\n#EXTINF:6.0,\nseg002.ts\n';

StreamHealthChecker checkerFor(Future<http.Response> Function(http.Request r) h) =>
    StreamHealthChecker(client: MockClient(h), policy: policy, timeout: const Duration(seconds: 2));

void main() {
  group('UrlPolicy', () {
    test('accepts https on allowlisted domains and subdomains', () {
      expect(policy.isStreamAllowed('https://streams.example.com/a.m3u8'), isTrue);
      expect(policy.isStreamAllowed('https://cdn1.streams.example.com/a.m3u8'), isTrue);
    });
    test('rejects invalid, cleartext, credentials and look-alike domains', () {
      expect(policy.streamProblem(''), 'empty');
      expect(policy.streamProblem('not a url'), 'malformed');
      expect(policy.streamProblem('http://streams.example.com/a.m3u8'), 'not_https');
      expect(policy.streamProblem('file:///sdcard/a.m3u8'), 'malformed');
      expect(policy.streamProblem('javascript:alert(1)'), 'malformed');
      expect(policy.streamProblem('https://u:p@streams.example.com/a'), 'credentials_in_url');
      expect(policy.streamProblem('https://evilstreams.example.com/a'), 'domain_not_allowed');
      expect(policy.streamProblem('https://streams.example.com.evil.net/a'), 'domain_not_allowed');
      expect(policy.isOfficialAllowed('https://rtmklik.rtm.gov.my/'), isTrue);
      expect(policy.isOfficialAllowed('https://rtm.gov.my.phish.io/'), isFalse);
    });
    test('redactUrl hides tokens and paths', () {
      final r = redactUrl('https://cdn.example.com/live/secret/path/index.m3u8?token=abc&exp=1');
      expect(r, 'https://cdn.example.com/…/index.m3u8?<redacted>');
      expect(Diagnostics.scrub('ip 203.0.113.9 token=abc123'), 'ip <redacted> token=<redacted>');
    });
  });

  group('StreamHealthChecker', () {
    test('ONLINE only when master, variant and first segment all work', () async {
      final seen = <String>[];
      final c = checkerFor((r) async {
        seen.add(r.url.path);
        if (r.url.path.endsWith('master.m3u8')) return http.Response(master, 200);
        if (r.url.path.endsWith('low/index.m3u8')) return http.Response(media, 200);
        if (r.url.path.endsWith('seg002.ts')) {
          expect(r.headers['Range'], 'bytes=0-2047');
          return http.Response('TSDATA', 206);
        }
        return http.Response('', 404);
      });
      final res = await c.check('https://streams.example.com/tv/master.m3u8', StreamType.hls);
      expect(res.status, StreamStatus.online);
      // The newest segment is tested (old ones rotate out of live playlists).
      expect(seen, ['/tv/master.m3u8', '/tv/low/index.m3u8', '/tv/low/seg002.ts']);
    });

    test('HTTP 200 with an HTML page is NOT online', () async {
      final c = checkerFor((_) async => http.Response('<html>Welcome</html>', 200));
      final res = await c.check('https://streams.example.com/a.m3u8', StreamType.hls);
      expect(res.status, StreamStatus.unknown);
      expect(res.detail, 'not_an_hls_playlist');
    });

    test('playlist OK but segment 404 is OFFLINE', () async {
      final c = checkerFor((r) async =>
          r.url.path.endsWith('.m3u8') ? http.Response(media, 200) : http.Response('', 404));
      final res = await c.check('https://streams.example.com/a.m3u8', StreamType.hls);
      expect(res.status, StreamStatus.offline);
    });

    test('geo-blocking message is recognised', () async {
      final c = checkerFor((_) async => http.Response('This content is not available in your country', 403));
      expect((await c.check('https://streams.example.com/a.m3u8', StreamType.hls)).status,
          StreamStatus.geoRestricted);
      final c451 = checkerFor((_) async => http.Response('', 451));
      expect((await c451.check('https://streams.example.com/a.m3u8', StreamType.hls)).status,
          StreamStatus.geoRestricted);
    });

    test('plain 403 outside the allowed region is GEO_RESTRICTED, otherwise UNKNOWN', () async {
      final c = checkerFor((_) async => http.Response('Forbidden', 403));
      final outside = await c.check('https://streams.example.com/a.m3u8', StreamType.hls,
          geoAllowed: ['MY'], userCountry: 'US');
      expect(outside.status, StreamStatus.geoRestricted);
      final inside = await c.check('https://streams.example.com/a.m3u8', StreamType.hls,
          geoAllowed: ['MY'], userCountry: 'MY');
      expect(inside.status, StreamStatus.unknown);
    });

    test('401 → AUTH_REQUIRED, 410 / signed-URL 403 → EXPIRED, 404/5xx → OFFLINE', () async {
      Future<StreamStatus> st(int code, [String url = 'https://streams.example.com/a.m3u8']) async =>
          (await checkerFor((_) async => http.Response('', code)).check(url, StreamType.hls)).status;
      expect(await st(401), StreamStatus.authRequired);
      expect(await st(410), StreamStatus.expired);
      expect(await st(403, 'https://streams.example.com/a.m3u8?token=x&expires=1'), StreamStatus.expired);
      expect(await st(404), StreamStatus.offline);
      expect(await st(503), StreamStatus.offline);
    });

    test('timeout → TIMEOUT', () async {
      final c = checkerFor((_) => Completer<http.Response>().future);
      final res = await c.check('https://streams.example.com/a.m3u8', StreamType.hls);
      expect(res.status, StreamStatus.timeout);
    });

    test('invalid / non-allowlisted URL is never requested', () async {
      var calls = 0;
      final c = checkerFor((_) async {
        calls++;
        return http.Response(media, 200);
      });
      final r1 = await c.check('http://streams.example.com/a.m3u8', StreamType.hls);
      final r2 = await c.check('https://pirate.example.org/a.m3u8', StreamType.hls);
      expect(r1.detail, startsWith('rejected_by_policy'));
      expect(r2.detail, startsWith('rejected_by_policy'));
      expect(calls, 0);
    });

    test('channel check falls back to secondary URL', () async {
      final c = checkerFor((r) async {
        if (r.url.host == 'streams.example.com' && r.url.path.startsWith('/primary')) return http.Response('', 503);
        return r.url.path.endsWith('.m3u8') ? http.Response(media, 200) : http.Response('x', 200);
      });
      final res = await c.checkChannel(hlsChannel(
          url: 'https://streams.example.com/primary/a.m3u8', secondary: 'https://streams.example.com/b/a.m3u8'));
      expect(res.status, StreamStatus.online);
    });

    test('checkAll respects the concurrency limit', () async {
      var active = 0, peak = 0;
      final c = checkerFor((r) async {
        active++;
        peak = active > peak ? active : peak;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
        return http.Response('', 404);
      });
      final chans = List.generate(6, (i) => hlsChannel(id: 'my_c$i'));
      final res = await c.checkAll(chans, concurrency: 2, pause: Duration.zero);
      expect(res.length, 6);
      expect(peak, lessThanOrEqualTo(2));
    });
  });

  group('GeoService', () {
    test('parses Cloudflare trace and JSON, ignores the IP', () {
      expect(
          GeoService.parseCountry('fl=1\nip=203.0.113.1\nloc=MY\n', GeoEndpoint(url: '', format: 'cloudflare_trace')),
          'MY');
      expect(GeoService.parseCountry('{"country_code":"sg"}', GeoEndpoint(url: '', format: 'json')), 'SG');
      expect(GeoService.parseCountry('loc=XX', GeoEndpoint(url: '', format: 'cloudflare_trace')), isNull);
    });
    test('falls through to the next endpoint on failure', () async {
      final g = GeoService(
          client: MockClient((r) async =>
              r.url.host == 'a.example.com' ? http.Response('', 500) : http.Response('{"country_code":"BN"}', 200)));
      final info = await g.detect([
        GeoEndpoint(url: 'https://a.example.com/trace', format: 'cloudflare_trace'),
        GeoEndpoint(url: 'https://b.example.com/json', format: 'json'),
      ]);
      expect(info!.countryCode, 'BN');
      expect(info.source, 'b.example.com');
    });
  });

  group('Playback plan', () {
    test('primary then secondary; disallowed URLs dropped', () {
      final s = buildSources(
          hlsChannel(url: 'https://streams.example.com/p.m3u8', secondary: 'https://bad.example.org/s.m3u8'), policy);
      expect(s.map((e) => e.kind), [SourceKind.primary]);
      final s2 = buildSources(
          hlsChannel(url: 'https://streams.example.com/p.m3u8', secondary: 'https://streams.example.com/s.m3u8'),
          policy);
      expect(s2.map((e) => e.kind), [SourceKind.primary, SourceKind.secondary]);
    });

    test('recovery back-off is bounded', () {
      final p = RecoveryPolicy(maxRetriesPerSource: 2);
      expect(p.delayFor(1), const Duration(seconds: 2));
      expect(p.delayFor(2), const Duration(seconds: 4));
      expect(p.delayFor(10), const Duration(seconds: 15));
      expect(p.canRetry(2), isFalse);
    });

    test('player error parsing', () {
      expect(httpCodeFromPlayerError('InvalidResponseCodeException: Response code: 403'), 403);
      expect(statusFromPlayerError('Response code: 401'), StreamStatus.authRequired);
      expect(statusFromPlayerError('Response code: 404'), StreamStatus.offline);
      expect(statusFromPlayerError('java.net.SocketTimeoutException: timeout'), StreamStatus.timeout);
    });

    test('alternatives: explicit first, then same category, skip failing/geo-blocked', () {
      final a = hlsChannel(id: 'my_a', category: 'news', alternatives: ['my_d']);
      final b = hlsChannel(id: 'my_b', category: 'news');
      final c = hlsChannel(id: 'my_c', category: 'news', availability: StreamStatus.offline);
      final d = hlsChannel(id: 'my_d', category: 'entertainment');
      final e = hlsChannel(id: 'sg_e', country: 'SG', category: 'news', geo: ['SG']);
      final f = hlsChannel(id: 'sg_f', country: 'SG', category: 'news');
      final noStream = Channel(id: 'my_g', name: 'G', countryCode: 'MY', category: 'news');
      final alts = findAlternatives(a, [a, b, c, d, e, f, noStream], userCountry: 'MY');
      expect(alts.map((x) => x.id), ['my_d', 'my_b', 'sg_f']);
    });
  });

  group('PlaybackController (auto reconnect / fallback)', () {
    test('retries the primary a bounded number of times, then secondary, then fails with diagnosis', () {
      fakeAsync((fa) {
        final backend = FakeBackend()..failUrls.addAll(['p', 's']);
        var diagnosed = 0;
        final ctrl = PlaybackController(
          backend: backend,
          policy: policy,
          recovery: RecoveryPolicy(maxRetriesPerSource: 2, baseDelay: const Duration(seconds: 1)),
          diagnose: (_) async {
            diagnosed++;
            return HealthResult(StreamStatus.geoRestricted, detail: 'provider_geo_message');
          },
        );
        ctrl.start(hlsChannel(url: 'https://streams.example.com/p', secondary: 'https://streams.example.com/s'));
        fa.elapse(const Duration(minutes: 2));
        // 1 + 2 retries on primary, 1 + 2 on secondary.
        expect(backend.opened.where((u) => u.endsWith('/p')).length, 3);
        expect(backend.opened.where((u) => u.endsWith('/s')).length, 3);
        expect(ctrl.phase, PlayerPhase.failed);
        expect(ctrl.failure!.status, StreamStatus.geoRestricted);
        expect(diagnosed, 1);
        // No further attempts happen later: no infinite loop.
        fa.elapse(const Duration(minutes: 10));
        expect(backend.opened.length, 6);
        ctrl.dispose();
      });
    });

    test('reconnects after a runtime error and reports success', () {
      fakeAsync((fa) {
        final backend = FakeBackend();
        var started = 0;
        final ctrl = PlaybackController(
          backend: backend,
          policy: policy,
          recovery: RecoveryPolicy(maxRetriesPerSource: 2, baseDelay: const Duration(seconds: 1)),
          onPlaybackStarted: (_) => started++,
        );
        ctrl.start(hlsChannel(url: 'https://streams.example.com/p'));
        fa.flushMicrotasks();
        expect(ctrl.phase, PlayerPhase.playing);
        backend.emit(BackendEvent(BackendEventType.error, message: 'Source error: unable to connect'));
        fa.flushMicrotasks();
        expect(ctrl.phase, PlayerPhase.reconnecting);
        fa.elapse(const Duration(seconds: 2));
        expect(ctrl.phase, PlayerPhase.playing);
        expect(backend.opened.length, 2);
        expect(started, 2);
        ctrl.dispose();
      });
    });

    test('stalled buffering triggers reconnect', () {
      fakeAsync((fa) {
        final backend = FakeBackend();
        final ctrl = PlaybackController(
          backend: backend,
          policy: policy,
          recovery: RecoveryPolicy(maxRetriesPerSource: 1, baseDelay: const Duration(seconds: 1)),
          stallTimeout: const Duration(seconds: 10),
        );
        ctrl.start(hlsChannel(url: 'https://streams.example.com/p'));
        fa.flushMicrotasks();
        backend.emit(BackendEvent(BackendEventType.buffering, value: true));
        expect(ctrl.phase, PlayerPhase.buffering);
        fa.elapse(const Duration(seconds: 12));
        expect(backend.opened.length, 2);
        ctrl.dispose();
      });
    });

    test('permanent errors (401) skip retries of the same URL', () {
      fakeAsync((fa) {
        final backend = FakeBackend()..failUrls.add('p')..failMessage = 'Response code: 401';
        final ctrl = PlaybackController(
          backend: backend,
          policy: policy,
          recovery: RecoveryPolicy(maxRetriesPerSource: 3, baseDelay: const Duration(seconds: 1)),
        );
        ctrl.start(hlsChannel(url: 'https://streams.example.com/p'));
        fa.elapse(const Duration(seconds: 30));
        expect(backend.opened.length, 1);
        expect(ctrl.failure!.status, StreamStatus.authRequired);
        ctrl.dispose();
      });
    });

    test('channel without a verified stream fails immediately with no network access', () {
      fakeAsync((fa) {
        final backend = FakeBackend();
        final ctrl = PlaybackController(backend: backend, policy: policy, recovery: RecoveryPolicy());
        ctrl.start(Channel(id: 'my_x', name: 'X', countryCode: 'MY', officialUrl: 'https://rtmklik.rtm.gov.my/'));
        fa.flushMicrotasks();
        expect(ctrl.phase, PlayerPhase.failed);
        expect(ctrl.failure!.detail, 'no_direct_stream');
        expect(backend.opened, isEmpty);
        ctrl.dispose();
      });
    });

    test('switching channel cancels pending retries of the old one', () {
      fakeAsync((fa) {
        final backend = FakeBackend()..failUrls.add('old');
        final ctrl = PlaybackController(
            backend: backend, policy: policy, recovery: RecoveryPolicy(baseDelay: const Duration(seconds: 5)));
        ctrl.start(hlsChannel(id: 'my_old', url: 'https://streams.example.com/old'));
        fa.flushMicrotasks();
        expect(ctrl.phase, PlayerPhase.reconnecting);
        ctrl.start(hlsChannel(id: 'my_new', url: 'https://streams.example.com/new'));
        fa.elapse(const Duration(minutes: 1));
        expect(backend.opened.where((u) => u.endsWith('/old')).length, 1);
        expect(ctrl.channel!.id, 'my_new');
        expect(ctrl.phase, PlayerPhase.playing);
        ctrl.dispose();
      });
    });
  });
}

class FakeBackend implements MediaBackend {
  final opened = <String>[];
  final failUrls = <String>{};
  String failMessage = 'Source error: Response code: 503';
  void Function(BackendEvent e)? cb;

  @override
  set onEvent(void Function(BackendEvent e)? c) => cb = c;

  void emit(BackendEvent e) => cb?.call(e);

  @override
  Future<void> open(PlaybackSource source) async {
    opened.add(source.url);
    if (failUrls.contains(source.url.split('/').last)) throw Exception(failMessage);
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> setVolume(double v) async {}
}
