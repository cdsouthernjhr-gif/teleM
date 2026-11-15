// Structural validation of the JSON database. Pure Dart, shared by the app
// (before accepting a downloaded update) and by `tool/validate_db.dart` (CI).

import '../core/url_policy.dart';
import 'models.dart';

class ValidationReport {
  final List<String> errors = [];
  final List<String> warnings = [];

  bool get isValid => errors.isEmpty;

  @override
  String toString() =>
      'errors(${errors.length}): ${errors.join('; ')}\nwarnings(${warnings.length}): ${warnings.join('; ')}';
}

class SchemaValidator {
  static const _idPattern = r'^[a-z]{2}_[a-z0-9_]+$';
  static final _id = RegExp(_idPattern);
  static final _date = RegExp(r'^\d{4}-\d{2}-\d{2}');

  /// Validates all five documents together (cross-references included).
  static ValidationReport validate(Map<String, Map<String, dynamic>?> raw) {
    final r = ValidationReport();
    for (final f in DatabaseBundle.fileNames) {
      if (raw[f] == null) r.errors.add('$f: missing or not a JSON object');
    }
    if (!r.isValid) return r;

    final cfg = raw['app_config.json']!;
    final countriesDoc = raw['countries.json']!;
    final categoriesDoc = raw['categories.json']!;
    final channelsDoc = raw['channels.json']!;
    final epgDoc = raw['epg.json']!;

    // app_config.json
    final dbVersion = cfg['database_version'];
    if (dbVersion is! int || dbVersion < 1) {
      r.errors.add('app_config.json: database_version must be an integer >= 1');
    }
    for (final k in ['allowed_stream_domains', 'allowed_official_domains']) {
      final v = cfg[k];
      if (v is! List || v.any((e) => e is! String || (e).contains('/') || e.contains(':'))) {
        r.errors.add('app_config.json: $k must be a list of bare host names');
      }
    }
    final geo = cfg['geo'];
    if (geo is Map && geo['endpoints'] is List) {
      for (final e in geo['endpoints'] as List) {
        final url = e is Map ? e['url']?.toString() ?? '' : '';
        if (UrlPolicy.basicProblem(url) != null) {
          r.errors.add('app_config.json: geo endpoint "$url" must be a valid https URL');
        }
      }
    }

    final ts = cfg['test_stream'];
    if (ts is Map && (ts['url']?.toString() ?? '').isNotEmpty) {
      final p = UrlPolicy(
        streamDomains: (cfg['allowed_stream_domains'] as List?)?.whereType<String>().toList() ?? const [],
        officialDomains: const [],
      ).streamProblem(ts['url'].toString());
      if (p != null) r.errors.add('app_config.json: test_stream.url rejected ($p)');
    }

    // countries.json
    final countryCodes = <String>{};
    final countries = countriesDoc['countries'];
    if (countries is! List || countries.isEmpty) {
      r.errors.add('countries.json: "countries" must be a non-empty list');
    } else {
      for (final c in countries) {
        final code = c is Map ? c['code'] : null;
        if (code is! String || !RegExp(r'^[A-Z]{2}$').hasMatch(code)) {
          r.errors.add('countries.json: invalid country code "$code"');
        } else if (!countryCodes.add(code)) {
          r.errors.add('countries.json: duplicate country "$code"');
        }
        if (c is Map && (c['name_ms'] is! String || c['name_en'] is! String)) {
          r.errors.add('countries.json: $code needs name_ms and name_en');
        }
      }
    }

    // categories.json
    final categoryIds = <String>{};
    final cats = categoriesDoc['categories'];
    if (cats is! List || cats.isEmpty) {
      r.errors.add('categories.json: "categories" must be a non-empty list');
    } else {
      for (final c in cats) {
        final id = c is Map ? c['id'] : null;
        if (id is! String || id.isEmpty) {
          r.errors.add('categories.json: category without id');
        } else if (!categoryIds.add(id)) {
          r.errors.add('categories.json: duplicate category "$id"');
        }
      }
      if (!categoryIds.contains(Category.all)) {
        r.errors.add('categories.json: must include the "all" category');
      }
    }

    // channels.json
    if (channelsDoc['version'] is! int) r.errors.add('channels.json: version must be an integer');
    if (dbVersion is int && channelsDoc['version'] is int && channelsDoc['version'] != dbVersion) {
      r.errors.add('channels.json: version (${channelsDoc['version']}) must equal app_config.database_version ($dbVersion)');
    }
    final upd = channelsDoc['updated_at'];
    if (upd is! String || !_date.hasMatch(upd)) {
      r.errors.add('channels.json: updated_at must be a YYYY-MM-DD date');
    }

    final policy = UrlPolicy(
      streamDomains: (cfg['allowed_stream_domains'] as List?)?.whereType<String>().toList() ?? const [],
      officialDomains: (cfg['allowed_official_domains'] as List?)?.whereType<String>().toList() ?? const [],
    );

    final ids = <String>{};
    final alternativesToCheck = <String, List>{};
    final groups = channelsDoc['countries'];
    if (groups is! List || groups.isEmpty) {
      r.errors.add('channels.json: "countries" must be a non-empty list');
      return r;
    }
    for (final g in groups) {
      if (g is! Map) {
        r.errors.add('channels.json: country group must be an object');
        continue;
      }
      final code = g['code'];
      if (!countryCodes.contains(code)) {
        r.errors.add('channels.json: country "$code" is not defined in countries.json');
      }
      final list = g['channels'];
      if (list is! List) {
        r.errors.add('channels.json: $code.channels must be a list');
        continue;
      }
      for (final ch in list) {
        if (ch is! Map) {
          r.errors.add('channels.json: $code has a non-object channel');
          continue;
        }
        final id = ch['id'];
        final where = 'channels.json[$id]';
        if (id is! String || !_id.hasMatch(id)) {
          r.errors.add('$where: id must match $_idPattern');
        } else if (!ids.add(id)) {
          r.errors.add('$where: duplicate id');
        } else if (code is String && !id.startsWith('${code.toLowerCase()}_')) {
          r.warnings.add('$where: id prefix does not match country $code');
        }
        if (ch['name'] is! String || (ch['name'] as String).trim().isEmpty) {
          r.errors.add('$where: name is required');
        }
        final cat = ch['category'];
        if (cat is! String || !categoryIds.contains(cat) || cat == Category.all) {
          r.errors.add('$where: category "$cat" is not defined in categories.json');
        }
        if (ch['enabled'] is! bool) r.errors.add('$where: enabled must be true/false');

        final st = ch['stream_type']?.toString() ?? '';
        if (!StreamType.values.any((t) => t.json == st)) {
          r.errors.add('$where: unknown stream_type "$st"');
        }
        final av = ch['availability']?.toString() ?? '';
        if (!StreamStatus.values.any((s) => s.json == av)) {
          r.errors.add('$where: unknown availability "$av"');
        }

        final streamUrl = ch['stream_url']?.toString() ?? '';
        final secondary = ch['secondary_url']?.toString() ?? '';
        final official = ch['official_url']?.toString() ?? '';
        for (final entry in {'stream_url': streamUrl, 'secondary_url': secondary}.entries) {
          if (entry.value.isEmpty) continue;
          final p = policy.streamProblem(entry.value);
          if (p != null) r.errors.add('$where: ${entry.key} rejected ($p)');
          if (!StreamType.parse(st).isPlayable) {
            r.errors.add('$where: ${entry.key} is set but stream_type "$st" is not playable');
          }
        }
        if (streamUrl.isNotEmpty && streamUrl == secondary) {
          r.warnings.add('$where: secondary_url duplicates stream_url');
        }
        if (official.isNotEmpty) {
          final p = policy.officialProblem(official);
          if (p != null) r.errors.add('$where: official_url rejected ($p)');
        } else {
          r.warnings.add('$where: no official_url');
        }
        if (streamUrl.isNotEmpty && official == streamUrl) {
          r.errors.add('$where: official_url and stream_url must be different');
        }

        final lc = ch['last_checked'];
        if (lc != null && (lc is! String || (lc.isNotEmpty && !_date.hasMatch(lc)))) {
          r.errors.add('$where: last_checked must be an ISO date or null');
        }
        if (av == StreamStatus.online.json && (lc == null || lc == '')) {
          r.errors.add('$where: availability "online" requires last_checked (status must come from a test)');
        }
        if (av == StreamStatus.online.json && streamUrl.isEmpty && secondary.isEmpty) {
          r.errors.add('$where: availability "online" requires a stream URL');
        }
        final alts = ch['alternatives'];
        if (alts != null) {
          if (alts is! List) {
            r.errors.add('$where: alternatives must be a list');
          } else if (id is String) {
            alternativesToCheck[id] = alts;
          }
        }
        final geoAllowed = ch['geo_allowed'];
        if (geoAllowed != null &&
            (geoAllowed is! List || geoAllowed.any((e) => e is! String || !RegExp(r'^[A-Z]{2}$').hasMatch(e)))) {
          r.errors.add('$where: geo_allowed must be a list of ISO country codes');
        }
      }
    }
    alternativesToCheck.forEach((id, alts) {
      for (final a in alts) {
        if (a == id) r.errors.add('channels.json[$id]: alternative refers to itself');
        if (!ids.contains(a)) r.errors.add('channels.json[$id]: alternative "$a" does not exist');
      }
    });

    // epg.json
    final progs = epgDoc['programs'];
    if (progs is! Map) {
      r.errors.add('epg.json: "programs" must be an object');
    } else {
      progs.forEach((k, v) {
        if (v is! List) {
          r.errors.add('epg.json: programs.$k must be a list');
          return;
        }
        for (final p in v) {
          if (p is! Map || EpgProgram.tryParse(Map<String, dynamic>.from(p)) == null) {
            r.errors.add('epg.json: invalid programme in $k (needs start < end and title)');
          }
        }
      });
    }
    return r;
  }
}
