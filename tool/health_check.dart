// Tests every stream URL in database/channels.json with the same checker the
// app uses (playlist + variant + first segment, max 2 concurrent requests).
//
//   dart run tool/health_check.dart [--country MY] [--write] [--json report.json]
//
// IMPORTANT: results depend on where you run it. Run it from a Malaysian
// connection to get the status Malaysian viewers will see. GitHub-hosted CI
// runners are in the US/EU, so GEO_RESTRICTED there does NOT mean the stream
// is broken in Malaysia.
//
// --write updates `availability` and `last_checked` in channels.json. Only a
// result of ONLINE is written as "online"; nothing is ever marked online
// without a successful test.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:my_asean_tv/core/url_policy.dart';
import 'package:my_asean_tv/data/models.dart';
import 'package:my_asean_tv/services/stream_health_checker.dart';

Future<void> main(List<String> args) async {
  String? arg(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final country = arg('--country')?.toUpperCase();
  final write = args.contains('--write');
  final jsonOut = arg('--json');

  final raw = <String, Map<String, dynamic>>{
    for (final f in DatabaseBundle.fileNames)
      f: jsonDecode(File('database/$f').readAsStringSync()) as Map<String, dynamic>,
  };
  final b = DatabaseBundle.fromRaw(raw);
  final policy = UrlPolicy(
      streamDomains: b.config.allowedStreamDomains, officialDomains: b.config.allowedOfficialDomains);
  final client = http.Client();
  final checker = StreamHealthChecker(
      client: client, policy: policy, timeout: Duration(seconds: b.config.healthTimeoutSeconds));

  final targets = b.channels
      .where((c) => c.enabled && (country == null || c.countryCode == country))
      .toList();
  final results = <String, HealthResult>{};
  stdout.writeln('Checking ${targets.length} channels (only those with a direct stream make requests)…');
  for (final c in targets) {
    final r = await checker.checkChannel(c);
    results[c.id] = r;
    stdout.writeln('${c.id.padRight(24)} ${r.status.label.padRight(15)} ${r.detail}');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  client.close();

  if (jsonOut != null) {
    File(jsonOut).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'checked_at': DateTime.now().toUtc().toIso8601String(),
      'note': 'Results depend on the network/country where this ran.',
      'results': results.map((k, v) => MapEntry(k, v.toJson())),
    }));
    stdout.writeln('Report written to $jsonOut');
  }

  if (write) {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    for (final g in raw['channels.json']!['countries'] as List) {
      for (final ch in (g as Map)['channels'] as List) {
        final m = ch as Map;
        final r = results[m['id']];
        if (r == null || r.detail == 'no_direct_stream') continue;
        m['availability'] = r.status.json;
        m['last_checked'] = today;
      }
    }
    File('database/channels.json')
        .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(raw['channels.json'])}\n');
    stdout.writeln('channels.json updated. Remember to bump database_version and channels.version.');
  }
  final online = results.values.where((r) => r.status == StreamStatus.online).length;
  stdout.writeln('Summary: $online ONLINE / ${results.length} checked.');
}
