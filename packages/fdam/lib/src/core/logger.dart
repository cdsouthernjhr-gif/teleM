// Technical log with redaction. Keeps the last entries in memory and
// optionally appends to a file. Never logs query strings (signed GitHub URLs
// carry credentials in the query) or user information.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum FdamLogLevel { debug, info, warn, error }

class FdamLogEntry {
  FdamLogEntry(this.time, this.level, this.tag, this.message);
  final DateTime time;
  final FdamLogLevel level;
  final String tag;
  final String message;

  @override
  String toString() => '${time.toUtc().toIso8601String()} ${level.name.toUpperCase()} [$tag] $message';
}

class FdamLogger {
  FdamLogger({this.capacity = 400, this.file, this.maxFileBytes = 512 * 1024, this.echo = kDebugMode});

  final int capacity;
  final File? file;
  final int maxFileBytes;
  final bool echo;
  final List<FdamLogEntry> _entries = [];
  Future<void> _fileQueue = Future.value();

  List<FdamLogEntry> get entries => List.unmodifiable(_entries);

  void debug(String tag, String msg) => _log(FdamLogLevel.debug, tag, msg);
  void info(String tag, String msg) => _log(FdamLogLevel.info, tag, msg);
  void warn(String tag, String msg) => _log(FdamLogLevel.warn, tag, msg);
  void error(String tag, String msg) => _log(FdamLogLevel.error, tag, msg);

  void _log(FdamLogLevel level, String tag, String msg) {
    final e = FdamLogEntry(DateTime.now(), level, tag, redactText(msg));
    _entries.add(e);
    if (_entries.length > capacity) _entries.removeRange(0, _entries.length - capacity);
    if (echo) debugPrint('FDAM $e');
    final f = file;
    if (f != null && level != FdamLogLevel.debug) {
      _fileQueue = _fileQueue.then((_) => _append(f, '$e\n')).catchError((_) {});
    }
  }

  Future<void> _append(File f, String line) async {
    try {
      if (await f.exists() && await f.length() > maxFileBytes) {
        final old = File('${f.path}.1');
        if (await old.exists()) await old.delete();
        await f.rename(old.path);
      }
      await f.parent.create(recursive: true);
      await f.writeAsString(line, mode: FileMode.append, flush: false);
    } catch (_) {
      // Logging must never break the app.
    }
  }

  Future<void> flush() => _fileQueue;
}

/// Removes query strings/fragments and user-info from any URL in [text].
String redactText(String text) => text.replaceAllMapped(
      RegExp(r'(https?://)([^/\s?#@]*@)?([^/\s?#]+)([^\s?#]*)(\?[^\s#]*)?(#\S*)?'),
      (m) => '${m[1]}${m[3]}${m[4]}${m[5] != null ? '?<redacted>' : ''}',
    );

/// Short form of a URL for logs: scheme://host/…/last-segment.
String redactUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || u.host.isEmpty) return '<invalid-url>';
  final last = u.pathSegments.isEmpty ? '' : u.pathSegments.last;
  return '${u.scheme}://${u.host}/…/$last${u.hasQuery ? '?<redacted>' : ''}';
}
