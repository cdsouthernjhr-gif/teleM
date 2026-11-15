// Geo-detection (spec §4A). Pure Dart.
//
// Uses the public endpoints listed in app_config.json (default: Cloudflare's
// /cdn-cgi/trace, which returns "loc=XX"). Only the two-letter country code is
// kept; the IP address in the response is never stored or logged.
// Detection can be disabled by the user in Settings.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/diagnostics.dart';
import '../core/url_policy.dart';
import '../data/models.dart';

class GeoInfo {
  GeoInfo(this.countryCode, this.source, this.detectedAt);
  final String countryCode;
  final String source;
  final DateTime detectedAt;

  Map<String, dynamic> toJson() =>
      {'country': countryCode, 'source': source, 'at': detectedAt.toIso8601String()};

  static GeoInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final c = j['country']?.toString() ?? '';
    final t = DateTime.tryParse(j['at']?.toString() ?? '');
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(c) || t == null) return null;
    return GeoInfo(c, j['source']?.toString() ?? '', t);
  }
}

class GeoService {
  GeoService({required this.client, this.timeout = const Duration(seconds: 6)});

  final http.Client client;
  final Duration timeout;

  static String? parseCountry(String body, GeoEndpoint ep) {
    String? code;
    if (ep.format == 'cloudflare_trace') {
      for (final line in const LineSplitter().convert(body)) {
        if (line.startsWith('loc=')) code = line.substring(4).trim();
      }
    } else {
      try {
        final j = jsonDecode(body);
        if (j is Map) code = j[ep.field]?.toString();
      } catch (_) {}
    }
    code = code?.toUpperCase();
    if (code == null || !RegExp(r'^[A-Z]{2}$').hasMatch(code) || code == 'XX' || code == 'T1') {
      return null;
    }
    return code;
  }

  Future<GeoInfo?> detect(List<GeoEndpoint> endpoints) async {
    for (final ep in endpoints) {
      if (UrlPolicy.basicProblem(ep.url) != null) continue;
      try {
        final resp = await client.get(Uri.parse(ep.url)).timeout(timeout);
        if (resp.statusCode != 200) continue;
        final code = parseCountry(resp.body, ep);
        if (code != null) {
          final host = Uri.parse(ep.url).host;
          diag.info('geo', 'country=$code via $host');
          return GeoInfo(code, host, DateTime.now());
        }
      } catch (e) {
        diag.warn('geo', 'endpoint failed: ${e.runtimeType}');
      }
    }
    return null;
  }
}
