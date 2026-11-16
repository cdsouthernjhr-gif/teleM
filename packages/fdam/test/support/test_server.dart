// Local HTTP server that behaves like GitHub raw + release downloads:
// ETag / If-None-Match, Range / If-Range, redirects, failure injection.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class RecordedRequest {
  RecordedRequest(this.method, this.path, this.headers);
  final String method;
  final String path;
  final Map<String, String> headers;
}

class TestServer {
  late HttpServer _server;
  final Map<String, Uint8List> files = {};
  final Map<String, String> etags = {};
  final Map<String, String> redirects = {};
  final Map<String, int> statusOverride = {};
  final List<RecordedRequest> requests = [];

  bool supportRange = true;
  bool sendEtag = true;
  bool sendContentLength = true;

  /// One-shot: drop the connection after this many body bytes.
  int? interruptAfterBytes;

  /// Number of upcoming requests to answer with 503.
  int failNext = 0;

  /// Delay between 16 KB chunks (to observe progress / pause).
  Duration chunkDelay = Duration.zero;

  /// Bytes to send instead of the real file (wrong content), one-shot per path.
  final Map<String, Uint8List> corruptOnce = {};

  int get port => _server.port;
  String get base => 'http://127.0.0.1:$port';
  String url(String path) => '$base$path';

  static Future<TestServer> start() async {
    final s = TestServer();
    s._server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s._server.listen(s._handle);
    return s;
  }

  Future<void> close() => _server.close(force: true);

  void put(String path, List<int> bytes) {
    files[path] = Uint8List.fromList(bytes);
    etags[path] = '"${sha256.convert(bytes).toString().substring(0, 16)}"';
  }

  void putJson(String path, Object json) => put(path, utf8.encode(jsonEncode(json)));

  int count(String path, {String method = 'GET'}) =>
      requests.where((r) => r.path == path && r.method == method).length;

  Future<void> _handle(HttpRequest req) async {
    final h = <String, String>{};
    req.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(','));
    final path = req.uri.path;
    requests.add(RecordedRequest(req.method, path, h));
    final res = req.response;
    try {
      if (failNext > 0) {
        failNext--;
        res.statusCode = 503;
        await res.close();
        return;
      }
      if (statusOverride.containsKey(path)) {
        res.statusCode = statusOverride[path]!;
        await res.close();
        return;
      }
      final redirect = redirects[path];
      if (redirect != null) {
        res.statusCode = 302;
        res.headers.set(HttpHeaders.locationHeader, redirect);
        await res.close();
        return;
      }
      var data = files[path];
      if (data == null) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      final etag = etags[path]!;
      if (sendEtag) res.headers.set(HttpHeaders.etagHeader, etag);
      res.headers.set(HttpHeaders.lastModifiedHeader, HttpDate.format(DateTime.utc(2026, 11, 1)));
      if (h['if-none-match'] == etag) {
        res.statusCode = 304;
        await res.close();
        return;
      }
      final corrupt = corruptOnce.remove(path);
      if (corrupt != null) data = corrupt;

      var start = 0;
      final range = h['range'];
      final ifRange = h['if-range'];
      final rangeOk = supportRange && range != null && (ifRange == null || ifRange == etag);
      if (rangeOk) {
        final m = RegExp(r'bytes=(\d+)-').firstMatch(range);
        start = int.parse(m![1]!);
        if (start >= data.length) {
          res.statusCode = 416;
          await res.close();
          return;
        }
        res.statusCode = 206;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${data.length - 1}/${data.length}');
      } else {
        res.statusCode = 200;
      }
      final body = data.sublist(start);
      if (sendContentLength) res.contentLength = body.length;
      if (req.method == 'HEAD') {
        await res.close();
        return;
      }
      final cut = interruptAfterBytes;
      if (cut != null && cut < body.length) {
        interruptAfterBytes = null;
        final socket = await res.detachSocket(writeHeaders: true);
        socket.add(body.sublist(0, cut));
        await socket.flush();
        socket.destroy();
        return;
      }
      const chunk = 16 * 1024;
      for (var i = 0; i < body.length; i += chunk) {
        res.add(body.sublist(i, i + chunk > body.length ? body.length : i + chunk));
        if (chunkDelay > Duration.zero) {
          await res.flush();
          await Future<void>.delayed(chunkDelay);
        }
      }
      await res.close();
    } catch (_) {
      // Client went away (cancel/pause).
    }
  }
}
