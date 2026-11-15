// Data models for the MY ASEAN TV JSON database.
//
// This file is pure Dart (no Flutter imports) so it can be reused by the
// command-line tools in `tool/` (database validator and health checker).

/// Stream health / availability status.
enum StreamStatus {
  online('online'),
  offline('offline'),
  geoRestricted('geo_restricted'),
  authRequired('auth_required'),
  expired('expired'),
  timeout('timeout'),
  unknown('unknown');

  const StreamStatus(this.json);
  final String json;

  static StreamStatus parse(Object? value) {
    final v = value?.toString().toLowerCase().trim();
    for (final s in StreamStatus.values) {
      if (s.json == v || s.name.toLowerCase() == v) return s;
    }
    return StreamStatus.unknown;
  }

  /// The upper-case label used in diagnostics and on the UI badge.
  String get label => json.toUpperCase();
}

/// How a channel is delivered.
enum StreamType {
  hls('hls'),
  dash('dash'),
  mp4('mp4'),

  /// Only an official web player exists; it must be opened externally.
  web('web'),

  /// Only an official streaming platform/app exists.
  platform('platform'),
  none('none');

  const StreamType(this.json);
  final String json;

  static StreamType parse(Object? value) {
    final v = value?.toString().toLowerCase().trim();
    for (final s in StreamType.values) {
      if (s.json == v) return s;
    }
    return StreamType.none;
  }

  /// True when the in-app player can play this type directly.
  bool get isPlayable =>
      this == StreamType.hls || this == StreamType.dash || this == StreamType.mp4;
}

DateTime? _parseDate(Object? v) {
  if (v == null) return null;
  final s = v.toString().trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

List<String> _stringList(Object? v) =>
    v is List ? v.map((e) => e.toString()).toList() : const <String>[];

String _str(Object? v) => v == null ? '' : v.toString();

class Channel {
  Channel({
    required this.id,
    required this.name,
    required this.countryCode,
    this.provider = '',
    this.type = 'FTA',
    this.category = 'general',
    this.logo = '',
    this.streamType = StreamType.none,
    this.streamUrl = '',
    this.secondaryUrl = '',
    this.officialUrl = '',
    this.officialPlatform = '',
    this.availability = StreamStatus.unknown,
    this.lastChecked,
    this.enabled = true,
    this.geoAllowed = const [],
    this.alternatives = const [],
    this.epgId = '',
    this.notes = '',
    this.verification = '',
  });

  final String id;
  final String name;
  final String countryCode;
  final String provider;

  /// "FTA" or "Digital".
  final String type;
  final String category;
  final String logo;
  final StreamType streamType;

  /// Primary direct stream URL (empty when not verified/available).
  final String streamUrl;

  /// Secondary (backup) direct stream URL, verified separately.
  final String secondaryUrl;

  /// Official web player / platform page; opened externally, never scraped.
  final String officialUrl;
  final String officialPlatform;

  /// Status recorded in the database by the maintainer's last check.
  final StreamStatus availability;
  final DateTime? lastChecked;
  final bool enabled;

  /// ISO country codes where the provider allows viewing (empty = unknown).
  final List<String> geoAllowed;

  /// Explicit alternative channel IDs, in preference order.
  final List<String> alternatives;
  final String epgId;
  final String notes;

  /// Free text describing how the URL was verified.
  final String verification;

  bool get hasDirectStream =>
      streamType.isPlayable && (streamUrl.isNotEmpty || secondaryUrl.isNotEmpty);

  factory Channel.fromJson(Map<String, dynamic> j, String countryCode) {
    return Channel(
      id: _str(j['id']),
      name: _str(j['name']),
      countryCode: countryCode,
      provider: _str(j['provider']),
      type: _str(j['type']).isEmpty ? 'FTA' : _str(j['type']),
      category: _str(j['category']).isEmpty ? 'general' : _str(j['category']),
      logo: _str(j['logo']),
      streamType: StreamType.parse(j['stream_type']),
      streamUrl: _str(j['stream_url']).trim(),
      secondaryUrl: _str(j['secondary_url']).trim(),
      officialUrl: _str(j['official_url']).trim(),
      officialPlatform: _str(j['official_platform']),
      availability: StreamStatus.parse(j['availability']),
      lastChecked: _parseDate(j['last_checked']),
      enabled: j['enabled'] != false,
      geoAllowed: _stringList(j['geo_allowed']).map((e) => e.toUpperCase()).toList(),
      alternatives: _stringList(j['alternatives']),
      epgId: _str(j['epg_id']),
      notes: _str(j['notes']),
      verification: _str(j['verification']),
    );
  }
}

class Country {
  Country({
    required this.code,
    required this.nameEn,
    required this.nameMs,
    this.order = 0,
    this.timezone = '',
    this.logoFolder = '',
  });

  final String code;
  final String nameEn;
  final String nameMs;
  final int order;
  final String timezone;
  final String logoFolder;

  String name(String lang) => lang == 'en' ? nameEn : nameMs;

  factory Country.fromJson(Map<String, dynamic> j) => Country(
        code: _str(j['code']).toUpperCase(),
        nameEn: _str(j['name_en']),
        nameMs: _str(j['name_ms']),
        order: (j['order'] as num?)?.toInt() ?? 0,
        timezone: _str(j['timezone']),
        logoFolder: _str(j['logo_folder']),
      );
}

class Category {
  Category({required this.id, required this.nameMs, required this.nameEn, this.order = 0});

  /// Virtual category that matches every channel.
  static const String all = 'all';

  final String id;
  final String nameMs;
  final String nameEn;
  final int order;

  String name(String lang) => lang == 'en' ? nameEn : nameMs;

  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: _str(j['id']),
        nameMs: _str(j['name_ms']),
        nameEn: _str(j['name_en']),
        order: (j['order'] as num?)?.toInt() ?? 0,
      );
}

class EpgProgram {
  EpgProgram({required this.start, required this.end, required this.title, this.description = ''});

  final DateTime start;
  final DateTime end;
  final String title;
  final String description;

  bool isOnAt(DateTime t) => !t.isBefore(start) && t.isBefore(end);

  static EpgProgram? tryParse(Map<String, dynamic> j) {
    final s = _parseDate(j['start']);
    final e = _parseDate(j['end']);
    final title = _str(j['title']);
    if (s == null || e == null || title.isEmpty || !e.isAfter(s)) return null;
    return EpgProgram(start: s, end: e, title: title, description: _str(j['description']));
  }
}

class Epg {
  Epg({this.version = 0, this.programs = const {}});

  final int version;
  final Map<String, List<EpgProgram>> programs;

  List<EpgProgram> forChannel(String epgId) => programs[epgId] ?? const [];

  /// Current programme and the next few after it.
  List<EpgProgram> upcoming(String epgId, DateTime now, {int count = 3}) {
    final list = forChannel(epgId).where((p) => p.end.isAfter(now)).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return list.take(count).toList();
  }

  factory Epg.fromJson(Map<String, dynamic> j) {
    final out = <String, List<EpgProgram>>{};
    final progs = j['programs'];
    if (progs is Map) {
      progs.forEach((key, value) {
        if (value is List) {
          out[key.toString()] = value
              .whereType<Map>()
              .map((m) => EpgProgram.tryParse(Map<String, dynamic>.from(m)))
              .whereType<EpgProgram>()
              .toList();
        }
      });
    }
    return Epg(version: (j['version'] as num?)?.toInt() ?? 0, programs: out);
  }
}

class GeoEndpoint {
  GeoEndpoint({required this.url, required this.format, this.field = 'country_code'});

  final String url;

  /// `cloudflare_trace` (key=value lines, uses `loc`) or `json`.
  final String format;
  final String field;

  factory GeoEndpoint.fromJson(Map<String, dynamic> j) => GeoEndpoint(
        url: _str(j['url']),
        format: _str(j['format']).isEmpty ? 'json' : _str(j['format']),
        field: _str(j['field']).isEmpty ? 'country_code' : _str(j['field']),
      );
}

class AppConfig {
  AppConfig({
    required this.databaseVersion,
    this.minAppBuild = 1,
    this.updatedAt,
    this.allowedStreamDomains = const [],
    this.allowedOfficialDomains = const [],
    this.geoEndpoints = const [],
    this.healthTimeoutSeconds = 10,
    this.healthMaxConcurrency = 2,
    this.maxRetriesPerSource = 2,
    this.retryBaseSeconds = 2,
    this.stallTimeoutSeconds = 20,
    this.announcementMs = '',
    this.announcementEn = '',
    this.testStreamUrl = '',
    this.testStreamName = '',
  });

  /// Public HLS test stream for verifying the player on a device.
  final String testStreamUrl;
  final String testStreamName;

  final int databaseVersion;
  final int minAppBuild;
  final DateTime? updatedAt;
  final List<String> allowedStreamDomains;
  final List<String> allowedOfficialDomains;
  final List<GeoEndpoint> geoEndpoints;
  final int healthTimeoutSeconds;
  final int healthMaxConcurrency;
  final int maxRetriesPerSource;
  final int retryBaseSeconds;
  final int stallTimeoutSeconds;
  final String announcementMs;
  final String announcementEn;

  factory AppConfig.fromJson(Map<String, dynamic> j) {
    final geo = j['geo'] is Map ? Map<String, dynamic>.from(j['geo'] as Map) : const {};
    final health = j['health'] is Map ? Map<String, dynamic>.from(j['health'] as Map) : const {};
    final pb = j['playback'] is Map ? Map<String, dynamic>.from(j['playback'] as Map) : const {};
    final ann = j['announcement'] is Map ? Map<String, dynamic>.from(j['announcement'] as Map) : const {};
    int i(Map m, String k, int d) => (m[k] as num?)?.toInt() ?? d;
    return AppConfig(
      databaseVersion: (j['database_version'] as num?)?.toInt() ?? 0,
      minAppBuild: (j['min_app_build'] as num?)?.toInt() ?? 1,
      updatedAt: _parseDate(j['updated_at']),
      allowedStreamDomains: _stringList(j['allowed_stream_domains']).map((e) => e.toLowerCase()).toList(),
      allowedOfficialDomains: _stringList(j['allowed_official_domains']).map((e) => e.toLowerCase()).toList(),
      geoEndpoints: (geo['endpoints'] is List)
          ? (geo['endpoints'] as List)
              .whereType<Map>()
              .map((m) => GeoEndpoint.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : const [],
      healthTimeoutSeconds: i(health, 'timeout_seconds', 10).clamp(3, 30),
      healthMaxConcurrency: i(health, 'max_concurrency', 2).clamp(1, 4),
      maxRetriesPerSource: i(pb, 'max_retries_per_source', 2).clamp(0, 5),
      retryBaseSeconds: i(pb, 'retry_base_seconds', 2).clamp(1, 10),
      stallTimeoutSeconds: i(pb, 'stall_timeout_seconds', 20).clamp(8, 60),
      announcementMs: _str(ann['ms']),
      announcementEn: _str(ann['en']),
      testStreamUrl: j['test_stream'] is Map ? _str((j['test_stream'] as Map)['url']) : '',
      testStreamName: j['test_stream'] is Map ? _str((j['test_stream'] as Map)['name']) : '',
    );
  }
}

/// The five database documents, parsed together.
class DatabaseBundle {
  DatabaseBundle({
    required this.config,
    required this.channelsVersion,
    required this.updatedAt,
    required this.countries,
    required this.categories,
    required this.channels,
    required this.epg,
    required this.raw,
  });

  final AppConfig config;
  final int channelsVersion;
  final String updatedAt;
  final List<Country> countries;
  final List<Category> categories;
  final List<Channel> channels;
  final Epg epg;

  /// Raw JSON documents keyed by file name; used for caching.
  final Map<String, Map<String, dynamic>> raw;

  int get version => config.databaseVersion;

  static const fileNames = [
    'app_config.json',
    'countries.json',
    'categories.json',
    'channels.json',
    'epg.json',
  ];

  Channel? byId(String id) {
    for (final c in channels) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<Channel> channelsFor(String countryCode, {String category = Category.all}) =>
      channels
          .where((c) =>
              c.enabled &&
              c.countryCode == countryCode &&
              (category == Category.all || c.category == category))
          .toList();

  Country? country(String code) {
    for (final c in countries) {
      if (c.code == code) return c;
    }
    return null;
  }

  factory DatabaseBundle.fromRaw(Map<String, Map<String, dynamic>> raw) {
    final config = AppConfig.fromJson(raw['app_config.json']!);
    final countries = ((raw['countries.json']!['countries'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => Country.fromJson(Map<String, dynamic>.from(m)))
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final categories = ((raw['categories.json']!['categories'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => Category.fromJson(Map<String, dynamic>.from(m)))
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final ch = raw['channels.json']!;
    final channels = <Channel>[];
    for (final c in (ch['countries'] as List?) ?? const []) {
      if (c is! Map) continue;
      final code = _str(c['code']).toUpperCase();
      for (final x in (c['channels'] as List?) ?? const []) {
        if (x is Map) channels.add(Channel.fromJson(Map<String, dynamic>.from(x), code));
      }
    }
    return DatabaseBundle(
      config: config,
      channelsVersion: (ch['version'] as num?)?.toInt() ?? 0,
      updatedAt: _str(ch['updated_at']),
      countries: countries,
      categories: categories,
      channels: channels,
      epg: Epg.fromJson(raw['epg.json']!),
      raw: raw,
    );
  }
}
