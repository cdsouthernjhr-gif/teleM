// HTTPS client that also trusts the ISRG (Let's Encrypt) roots.
//
// Android 6.0 (API 23) ships a CA store that does not contain ISRG Root X1/X2,
// so HTTPS servers using Let's Encrypt certificates fail there. We ADD the two
// public roots (bundled in assets/certs) on top of the system store - we never
// disable certificate verification.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'diagnostics.dart';

Future<http.Client> createHttpClient() async {
  final ctx = SecurityContext(withTrustedRoots: true);
  for (final f in ['assets/certs/isrg_root_x1.pem', 'assets/certs/isrg_root_x2.pem']) {
    try {
      final data = await rootBundle.load(f);
      ctx.setTrustedCertificatesBytes(data.buffer.asUint8List());
    } catch (e) {
      // Already trusted by the system store (newer Android) or asset missing.
      diag.info('tls', 'extra root ${f.split('/').last}: ${e.runtimeType}');
    }
  }
  final hc = HttpClient(context: ctx)
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 4
    ..userAgent = 'MYASEANTV/1.0 (Android)';
  return IOClient(hc);
}
