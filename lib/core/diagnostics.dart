// In-memory diagnostic log (ring buffer). Pure Dart.
//
// Never log full URLs, tokens, IP addresses or credentials: callers pass URLs
// through `redactUrl` and this logger additionally scrubs common secrets.

class DiagEntry {
  DiagEntry(this.time, this.level, this.tag, this.message);
  final DateTime time;
  final String level;
  final String tag;
  final String message;

  @override
  String toString() =>
      '${time.toIso8601String().substring(0, 19)} [$level] $tag: $message';
}

class Diagnostics {
  Diagnostics._();
  static final Diagnostics instance = Diagnostics._();

  static const int capacity = 300;
  final List<DiagEntry> _entries = [];

  List<DiagEntry> get entries => List.unmodifiable(_entries);

  static final _secretPatterns = <RegExp>[
    RegExp(r'(token|key|sig|signature|auth|password|passwd|secret|hdnts|hdnea|session)=([^&\s]+)',
        caseSensitive: false),
    RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'), // IPv4
    RegExp(r'\b([0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}\b', caseSensitive: false), // IPv6
    RegExp(r'Bearer\s+\S+', caseSensitive: false),
  ];

  static String scrub(String s) {
    var out = s;
    for (final p in _secretPatterns) {
      out = out.replaceAllMapped(p, (m) {
        if (m.groupCount >= 2 && m.group(1) != null && m.group(2) != null) {
          return '${m.group(1)}=<redacted>';
        }
        return '<redacted>';
      });
    }
    return out;
  }

  void log(String tag, String message, {String level = 'I'}) {
    _entries.add(DiagEntry(DateTime.now(), level, tag, scrub(message)));
    if (_entries.length > capacity) _entries.removeRange(0, _entries.length - capacity);
  }

  void info(String tag, String m) => log(tag, m);
  void warn(String tag, String m) => log(tag, m, level: 'W');
  void error(String tag, String m) => log(tag, m, level: 'E');

  void clear() => _entries.clear();

  String export() => _entries.map((e) => e.toString()).join('\n');
}

final diag = Diagnostics.instance;
