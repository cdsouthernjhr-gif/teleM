import 'dart:convert';
import 'dart:io';

import 'package:my_asean_tv/data/models.dart';

/// Reads the real database files shipped in `database/`.
Map<String, Map<String, dynamic>> realDatabase() => {
      for (final f in DatabaseBundle.fileNames)
        f: jsonDecode(File('database/$f').readAsStringSync()) as Map<String, dynamic>,
    };

/// Deep copy so tests can mutate freely.
Map<String, Map<String, dynamic>> copyDb(Map<String, Map<String, dynamic>> db) =>
    (jsonDecode(jsonEncode(db)) as Map<String, dynamic>).map((k, v) => MapEntry(k, v as Map<String, dynamic>));

/// A database that contains one playable HLS channel per country for tests.
Map<String, Map<String, dynamic>> playableDb({int version = 1}) {
  final db = copyDb(realDatabase());
  db['app_config.json']!['database_version'] = version;
  db['channels.json']!['version'] = version;
  (db['app_config.json']!['allowed_stream_domains'] as List).add('streams.example.com');
  final groups = db['channels.json']!['countries'] as List;
  final my = (groups.first as Map)['channels'] as List;
  final tv1 = my.first as Map;
  tv1['stream_type'] = 'hls';
  tv1['stream_url'] = 'https://streams.example.com/tv1/master.m3u8';
  tv1['secondary_url'] = 'https://backup.streams.example.com/tv1/index.m3u8';
  final tv2 = my[1] as Map;
  tv2['stream_type'] = 'hls';
  tv2['stream_url'] = 'https://streams.example.com/tv2/index.m3u8';
  tv2['availability'] = 'online';
  tv2['last_checked'] = '2026-11-15';
  return db;
}

Channel hlsChannel({
  String id = 'my_test',
  String url = 'https://streams.example.com/a/master.m3u8',
  String secondary = '',
  String category = 'news',
  String country = 'MY',
  List<String> geo = const [],
  List<String> alternatives = const [],
  StreamStatus availability = StreamStatus.unknown,
}) =>
    Channel(
      id: id,
      name: id.toUpperCase(),
      countryCode: country,
      category: category,
      streamType: StreamType.hls,
      streamUrl: url,
      secondaryUrl: secondary,
      officialUrl: 'https://rtmklik.rtm.gov.my/',
      geoAllowed: geo,
      alternatives: alternatives,
      availability: availability,
    );
