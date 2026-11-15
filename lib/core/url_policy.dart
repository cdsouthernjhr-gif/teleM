// URL safety policy. Pure Dart.
//
// Every URL is checked before it is played or opened:
//  * HTTPS only (no cleartext, no file:, content:, javascript:, data: ...).
//  * No embedded credentials (user:pass@host).
//  * Stream hosts must be in `allowed_stream_domains` from app_config.json.
//  * Official platform hosts must be in `allowed_official_domains`.

class UrlPolicy {
  UrlPolicy({required List<String> streamDomains, required List<String> officialDomains})
      : _stream = streamDomains.map(_norm).where((d) => d.isNotEmpty).toList(),
        _official = officialDomains.map(_norm).where((d) => d.isNotEmpty).toList();

  final List<String> _stream;
  final List<String> _official;

  static String _norm(String d) => d.trim().toLowerCase().replaceAll(RegExp(r'^\*?\.'), '');

  /// Returns null when the URL is acceptable, otherwise a short reason code.
  static String? basicProblem(String url) {
    if (url.trim().isEmpty) return 'empty';
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return 'malformed';
    if (uri.scheme != 'https') return 'not_https';
    if (uri.userInfo.isNotEmpty) return 'credentials_in_url';
    if (uri.hasPort && uri.port != 443 && (uri.port < 1 || uri.port > 65535)) return 'bad_port';
    return null;
  }

  static bool hostMatches(String host, List<String> domains) {
    final h = host.toLowerCase();
    for (final d in domains) {
      if (h == d || h.endsWith('.$d')) return true;
    }
    return false;
  }

  String? streamProblem(String url) {
    final p = basicProblem(url);
    if (p != null) return p;
    final host = Uri.parse(url.trim()).host;
    if (!hostMatches(host, _stream)) return 'domain_not_allowed';
    return null;
  }

  String? officialProblem(String url) {
    final p = basicProblem(url);
    if (p != null) return p;
    final host = Uri.parse(url.trim()).host;
    if (!hostMatches(host, _official)) return 'domain_not_allowed';
    return null;
  }

  bool isStreamAllowed(String url) => streamProblem(url) == null;
  bool isOfficialAllowed(String url) => officialProblem(url) == null;
}

/// Removes query strings, fragments and anything that could be a token so a
/// URL can be written to the diagnostic log.
String redactUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return '<invalid-url>';
  final segs = uri.pathSegments;
  final shortPath = segs.isEmpty ? '/' : '/…/${segs.last}';
  final q = uri.hasQuery ? '?<redacted>' : '';
  return '${uri.scheme}://${uri.host}$shortPath$q';
}
