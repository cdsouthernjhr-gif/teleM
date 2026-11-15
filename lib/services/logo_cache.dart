// Downloads channel logos once from the GitHub repository and keeps them on
// disk so they are available offline.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/diagnostics.dart';
import '../core/url_policy.dart';

class LogoCache {
  LogoCache({required this.client, required this.dir, required this.repoRootUrl, this.maxBytes = 300 * 1024});

  final http.Client client;
  final Directory dir;
  final String repoRootUrl;
  final int maxBytes;
  final Map<String, Future<File?>> _inflight = {};

  /// Resolves `logos/malaysia/tv1.png` against the repository root. Absolute
  /// URLs must be HTTPS and on the same host as the repository.
  String? resolve(String logo) {
    if (logo.isEmpty) return null;
    final root = Uri.parse(repoRootUrl.endsWith('/') ? repoRootUrl : '$repoRootUrl/');
    final u = logo.startsWith('https://') ? Uri.parse(logo) : root.resolve(logo);
    if (UrlPolicy.basicProblem(u.toString()) != null || u.host != root.host) return null;
    return u.toString();
  }

  String _fileName(String url) =>
      url.replaceFirst(RegExp(r'^https://'), '').replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  Future<File?> get(String logo) {
    final url = resolve(logo);
    if (url == null) return Future.value(null);
    return _inflight.putIfAbsent(url, () => _get(url));
  }

  Future<File?> _get(String url) async {
    final f = File('${dir.path}/${_fileName(url)}');
    if (await f.exists() && await f.length() > 0) return f;
    try {
      final resp = await client.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      final ct = resp.headers['content-type'] ?? '';
      final isImage = ct.startsWith('image/') || url.endsWith('.png') || url.endsWith('.jpg') || url.endsWith('.webp');
      if (resp.statusCode != 200 || !isImage || resp.bodyBytes.length > maxBytes || resp.bodyBytes.isEmpty) {
        _inflight.remove(url); // allow a later retry
        return null;
      }
      await dir.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(resp.bodyBytes, flush: true);
      await tmp.rename(f.path);
      return f;
    } catch (e) {
      diag.info('logo', 'not available: ${redactUrl(url)} (${e.runtimeType})');
      _inflight.remove(url);
      return null;
    }
  }
}
