// Stream health checker (spec §6). Pure Dart.
//
// The checker is deliberately polite: one playlist request, at most one
// variant playlist request and one small ranged segment request per check,
// limited concurrency, no scraping of web pages and no token extraction.
// A plain HTTP 200 is NOT treated as "online" - the playlist must parse and
// the first media segment must answer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/diagnostics.dart';
import '../core/url_policy.dart';
import '../data/models.dart';

class HealthResult {
  HealthResult(this.status, {this.httpCode, this.detail = '', DateTime? checkedAt, this.latencyMs})
      : checkedAt = checkedAt ?? DateTime.now();

  final StreamStatus status;
  final int? httpCode;
  final String detail;
  final DateTime checkedAt;
  final int? latencyMs;

  Map<String, dynamic> toJson() => {
        'status': status.json,
        if (httpCode != null) 'http': httpCode,
        'detail': detail,
        'checked_at': checkedAt.toIso8601String(),
        if (latencyMs != null) 'ms': latencyMs,
      };

  static HealthResult? fromJson(Object? j) {
    if (j is! Map) return null;
    final t = DateTime.tryParse(j['checked_at']?.toString() ?? '');
    if (t == null) return null;
    return HealthResult(StreamStatus.parse(j['status']),
        httpCode: (j['http'] as num?)?.toInt(),
        detail: j['detail']?.toString() ?? '',
        checkedAt: t,
        latencyMs: (j['ms'] as num?)?.toInt());
  }

  @override
  String toString() => '${status.label}${httpCode != null ? ' (HTTP $httpCode)' : ''} $detail';
}

class _Fetched {
  _Fetched(this.code, this.headers, this.body, this.finalUrl);
  final int code;
  final Map<String, String> headers;
  final String body;
  final Uri finalUrl;
}

class StreamHealthChecker {
  StreamHealthChecker({
    required this.client,
    required this.policy,
    this.timeout = const Duration(seconds: 10),
    this.maxBodyBytes = 256 * 1024,
    this.userAgent = 'MYASEANTV/1.0 (stream-health-check)',
  });

  final http.Client client;
  final UrlPolicy policy;
  final Duration timeout;
  final int maxBodyBytes;
  final String userAgent;

  static const _geoHints = [
    'geo',
    'not available in your',
    'not available in this',
    'outside',
    'your region',
    'your country',
    'territory',
    'tidak tersedia di',
    'negara anda',
    'wilayah anda',
  ];

  static bool _looksGeo(_Fetched f) {
    if (f.code == 451) return true;
    for (final h in f.headers.keys) {
      if (h.contains('geo') || h == 'x-blocked-reason') return true;
    }
    final b = f.body.toLowerCase();
    return _geoHints.any(b.contains);
  }

  static bool _hasTokenParams(Uri u) {
    const keys = ['token', 'expires', 'exp', 'hdnts', 'hdnea', 'signature', 'sig', 'policy', 'st', 'e'];
    return u.queryParameters.keys.any((k) => keys.contains(k.toLowerCase()));
  }

  Future<_Fetched> _get(Uri uri, {String? range}) async {
    final req = http.Request('GET', uri)
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers['User-Agent'] = userAgent;
    if (range != null) req.headers['Range'] = range;
    final resp = await client.send(req).timeout(timeout);
    final bytes = <int>[];
    final limit = range != null ? 4096 : maxBodyBytes;
    final sub = resp.stream.timeout(timeout);
    await for (final chunk in sub) {
      bytes.addAll(chunk);
      if (bytes.length >= limit) break;
    }
    return _Fetched(resp.statusCode, resp.headers, utf8.decode(bytes, allowMalformed: true),
        resp.request?.url ?? uri);
  }

  HealthResult _classifyHttpError(_Fetched f, Uri url, List<String> geoAllowed, String? userCountry, int ms) {
    final c = f.code;
    if (c == 401) return HealthResult(StreamStatus.authRequired, httpCode: c, detail: 'http_401', latencyMs: ms);
    if (c == 451 || ((c == 403 || c == 404) && _looksGeo(f))) {
      return HealthResult(StreamStatus.geoRestricted, httpCode: c, detail: 'provider_geo_message', latencyMs: ms);
    }
    if (c == 410) return HealthResult(StreamStatus.expired, httpCode: c, detail: 'http_410', latencyMs: ms);
    if (c == 403) {
      if (_hasTokenParams(url)) {
        return HealthResult(StreamStatus.expired, httpCode: c, detail: 'token_or_signature_expired', latencyMs: ms);
      }
      if (userCountry != null && geoAllowed.isNotEmpty && !geoAllowed.contains(userCountry)) {
        return HealthResult(StreamStatus.geoRestricted,
            httpCode: c, detail: 'http_403_outside_allowed_region', latencyMs: ms);
      }
      return HealthResult(StreamStatus.unknown, httpCode: c, detail: 'http_403_forbidden', latencyMs: ms);
    }
    if (c == 404) return HealthResult(StreamStatus.offline, httpCode: c, detail: 'http_404', latencyMs: ms);
    if (c == 429) return HealthResult(StreamStatus.unknown, httpCode: c, detail: 'rate_limited', latencyMs: ms);
    if (c >= 500) return HealthResult(StreamStatus.offline, httpCode: c, detail: 'server_error', latencyMs: ms);
    return HealthResult(StreamStatus.unknown, httpCode: c, detail: 'http_$c', latencyMs: ms);
  }

  static String? firstMediaLine(String playlist, {required bool master}) {
    final lines = const LineSplitter().convert(playlist).map((l) => l.trim()).toList();
    final tag = master ? '#EXT-X-STREAM-INF' : '#EXTINF';
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith(tag)) {
        for (var j = i + 1; j < lines.length; j++) {
          if (lines[j].isEmpty) continue;
          if (lines[j].startsWith('#')) continue;
          return lines[j];
        }
      }
    }
    return null;
  }

  /// Newest segment of a media playlist. Live playlists drop their oldest
  /// segments continuously, so testing the first one can give a false 404.
  static String? lastSegment(String playlist) {
    final lines = const LineSplitter().convert(playlist).map((l) => l.trim()).toList();
    String? last;
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].startsWith('#EXTINF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        if (lines[j].isEmpty || lines[j].startsWith('#')) continue;
        last = lines[j];
        break;
      }
    }
    return last;
  }

  static bool isHlsPlaylist(String body) => body.replaceFirst('﻿', '').trimLeft().startsWith('#EXTM3U');

  /// Checks one URL. [geoAllowed]/[userCountry] help interpret HTTP 403.
  Future<HealthResult> check(String url, StreamType type,
      {List<String> geoAllowed = const [], String? userCountry}) async {
    final problem = policy.streamProblem(url);
    if (problem != null) {
      return HealthResult(StreamStatus.unknown, detail: 'rejected_by_policy:$problem');
    }
    final uri = Uri.parse(url.trim());
    final sw = Stopwatch()..start();
    try {
      final f = await _get(uri, range: type == StreamType.mp4 ? 'bytes=0-4095' : null);
      final ms = sw.elapsedMilliseconds;
      if (f.code != 200 && f.code != 206) {
        return _classifyHttpError(f, uri, geoAllowed, userCountry, ms);
      }
      switch (type) {
        case StreamType.hls:
          return await _checkHls(f, geoAllowed, userCountry, sw);
        case StreamType.dash:
          if (f.body.contains('<MPD')) {
            return HealthResult(StreamStatus.online, httpCode: f.code, detail: 'dash_manifest_ok', latencyMs: ms);
          }
          return HealthResult(_looksGeo(f) ? StreamStatus.geoRestricted : StreamStatus.unknown,
              httpCode: f.code, detail: 'not_a_dash_manifest', latencyMs: ms);
        case StreamType.mp4:
          final ct = f.headers['content-type'] ?? '';
          final isMp4 = ct.startsWith('video/') || (f.body.length > 8 && f.body.substring(4, 8) == 'ftyp');
          return HealthResult(isMp4 ? StreamStatus.online : StreamStatus.unknown,
              httpCode: f.code, detail: isMp4 ? 'mp4_ok' : 'not_video_content', latencyMs: ms);
        default:
          return HealthResult(StreamStatus.unknown, detail: 'type_not_testable');
      }
    } on TimeoutException {
      return HealthResult(StreamStatus.timeout, detail: 'timeout_${timeout.inSeconds}s');
    } on HandshakeException catch (e) {
      diag.warn('health', 'TLS error ${redactUrl(url)}: ${e.message}');
      return HealthResult(StreamStatus.offline, detail: 'tls_error');
    } on SocketException catch (e) {
      return HealthResult(StreamStatus.offline, detail: 'network:${e.osError?.errorCode ?? e.message}');
    } on http.ClientException catch (e) {
      return HealthResult(StreamStatus.offline, detail: 'client:${e.message}');
    } catch (e) {
      return HealthResult(StreamStatus.unknown, detail: 'error:${e.runtimeType}');
    }
  }

  Future<HealthResult> _checkHls(_Fetched f, List<String> geoAllowed, String? userCountry, Stopwatch sw) async {
    if (!isHlsPlaylist(f.body)) {
      return HealthResult(_looksGeo(f) ? StreamStatus.geoRestricted : StreamStatus.unknown,
          httpCode: f.code, detail: 'not_an_hls_playlist', latencyMs: sw.elapsedMilliseconds);
    }
    var playlist = f;
    if (f.body.contains('#EXT-X-STREAM-INF')) {
      final variant = firstMediaLine(f.body, master: true);
      if (variant == null) {
        return HealthResult(StreamStatus.unknown, httpCode: f.code, detail: 'master_without_variants');
      }
      final vUri = f.finalUrl.resolve(variant);
      playlist = await _get(vUri);
      if (playlist.code != 200) {
        return _classifyHttpError(playlist, vUri, geoAllowed, userCountry, sw.elapsedMilliseconds);
      }
      if (!isHlsPlaylist(playlist.body)) {
        return HealthResult(StreamStatus.unknown, httpCode: playlist.code, detail: 'variant_not_hls');
      }
    }
    final seg = lastSegment(playlist.body);
    if (seg == null) {
      return HealthResult(StreamStatus.offline, httpCode: playlist.code, detail: 'playlist_has_no_segments');
    }
    final sUri = playlist.finalUrl.resolve(seg);
    final s = await _get(sUri, range: 'bytes=0-2047');
    final ms = sw.elapsedMilliseconds;
    if (s.code == 200 || s.code == 206) {
      return HealthResult(StreamStatus.online, httpCode: s.code, detail: 'playlist_and_segment_ok', latencyMs: ms);
    }
    return _classifyHttpError(s, sUri, geoAllowed, userCountry, ms);
  }

  /// Checks a channel: primary first, then the secondary URL.
  Future<HealthResult> checkChannel(Channel c, {String? userCountry}) async {
    if (!c.streamType.isPlayable || (c.streamUrl.isEmpty && c.secondaryUrl.isEmpty)) {
      return HealthResult(StreamStatus.unknown, detail: 'no_direct_stream');
    }
    HealthResult? first;
    for (final u in [c.streamUrl, c.secondaryUrl].where((u) => u.isNotEmpty)) {
      final r = await check(u, c.streamType, geoAllowed: c.geoAllowed, userCountry: userCountry);
      diag.info('health', '${c.id} ${redactUrl(u)} -> $r');
      if (r.status == StreamStatus.online) return r;
      first ??= r;
    }
    return first!;
  }

  /// Checks many channels with bounded concurrency and a small pause between
  /// requests so providers are not hammered.
  Future<Map<String, HealthResult>> checkAll(List<Channel> channels,
      {String? userCountry,
      int concurrency = 2,
      Duration pause = const Duration(milliseconds: 300),
      void Function(String id, HealthResult r)? onResult}) async {
    final out = <String, HealthResult>{};
    final queue = List<Channel>.from(channels);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final c = queue.removeAt(0);
        final r = await checkChannel(c, userCountry: userCountry);
        out[c.id] = r;
        onResult?.call(c.id, r);
        if (pause > Duration.zero) await Future<void>.delayed(pause);
      }
    }

    await Future.wait(List.generate(concurrency.clamp(1, 4), (_) => worker()));
    return out;
  }
}
