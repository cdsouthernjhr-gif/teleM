// Validates database/*.json. Used by CI and before every database commit.
//
//   dart run tool/validate_db.dart [database-dir]
//
// Exit code 0 = valid, 1 = errors.

import 'dart:convert';
import 'dart:io';

import 'package:my_asean_tv/data/models.dart';
import 'package:my_asean_tv/data/schema_validator.dart';

void main(List<String> args) {
  final dir = args.isEmpty ? 'database' : args.first;
  final raw = <String, Map<String, dynamic>?>{};
  for (final f in DatabaseBundle.fileNames) {
    final file = File('$dir/$f');
    if (!file.existsSync()) {
      raw[f] = null;
      continue;
    }
    try {
      final v = jsonDecode(file.readAsStringSync());
      raw[f] = v is Map<String, dynamic> ? v : null;
    } on FormatException catch (e) {
      stderr.writeln('$f: invalid JSON: ${e.message}');
      raw[f] = null;
    }
  }
  final r = SchemaValidator.validate(raw);
  for (final w in r.warnings) {
    stdout.writeln('WARNING $w');
  }
  for (final e in r.errors) {
    stderr.writeln('ERROR   $e');
  }
  if (r.isValid) {
    final b = DatabaseBundle.fromRaw(raw.map((k, v) => MapEntry(k, v!)));
    final withStream = b.channels.where((c) => c.hasDirectStream).length;
    stdout.writeln('OK: database v${b.version}, ${b.channels.length} channels '
        '($withStream with a direct stream), ${b.countries.length} countries.');
  }
  exit(r.isValid ? 0 : 1);
}
