// Dio wrapper that follows redirects manually so every hop can be checked
// against the allowed host list (GitHub release downloads redirect from
// github.com to a signed objects/release-assets URL).

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../core/config.dart';
import '../core/errors.dart';
import '../core/logger.dart';

class FdamHttp {
  FdamHttp(this.config, {Dio? dio, FdamLogger? logger})
      : log = logger ?? FdamLogger(),
        dio = dio ?? _createDio(config);

  final FdamConfig config;
  final Dio dio;
  final FdamLogger log;

  static Dio _createDio(FdamConfig c) {
    final d = Dio(BaseOptions(
      connectTimeout: c.connectTimeout,
      receiveTimeout: c.receiveTimeout,
      sendTimeout: c.connectTimeout,
      headers: {HttpHeaders.userAgentHeader: c.userAgent},
    ));
    d.httpClientAdapter = IOHttpClientAdapter(createHttpClient: c.httpClientFactory);
    return d;
  }

  /// GET [url] as a stream, following up to [FdamConfig.maxRedirects]
  /// redirects. Every hop must pass [FdamConfig.urlProblem]. The returned
  /// response can have any status code; the caller must check it and must
  /// consume or cancel the body stream.
  Future<Response<ResponseBody>> getStream(
    String url, {
    Map<String, String> headers = const {},
    CancelToken? cancelToken,
    bool head = false,
  }) async {
    var current = Uri.parse(url);
    for (var hop = 0; hop <= config.maxRedirects; hop++) {
      final problem = config.urlProblem(current.toString());
      if (problem != null) {
        throw FdamException(FdamErrorCode.invalidAssetPath, 'URL rejected ($problem): ${redactUrl(current.toString())}');
      }
      final Response<ResponseBody> resp;
      try {
        resp = await dio.requestUri<ResponseBody>(
          current,
          cancelToken: cancelToken,
          options: Options(
            method: head ? 'HEAD' : 'GET',
            responseType: ResponseType.stream,
            followRedirects: false,
            validateStatus: (_) => true,
            headers: headers,
          ),
        );
      } on DioException catch (e) {
        throw mapDioError(e, current.toString());
      }
      final code = resp.statusCode ?? 0;
      if (code >= 300 && code < 400 && code != 304) {
        final loc = resp.headers.value(HttpHeaders.locationHeader);
        await _discard(resp);
        if (loc == null || loc.isEmpty) {
          throw FdamException(FdamErrorCode.httpError, 'redirect $code without Location', httpStatus: code);
        }
        current = current.resolve(loc);
        continue;
      }
      return resp;
    }
    throw FdamException(FdamErrorCode.httpError, 'too many redirects for ${redactUrl(url)}');
  }

  /// Reads a whole (small) body into memory with a size cap.
  Future<List<int>> readBody(Response<ResponseBody> resp, int maxBytes) async {
    final out = <int>[];
    await for (final chunk in resp.data!.stream) {
      out.addAll(chunk);
      if (out.length > maxBytes) {
        throw FdamException(FdamErrorCode.manifestInvalid, 'body larger than $maxBytes bytes');
      }
    }
    return out;
  }

  static Future<void> _discard(Response<ResponseBody> resp) async {
    try {
      await resp.data?.stream.listen((_) {}).cancel();
    } catch (_) {}
  }

  static Future<void> discard(Response<ResponseBody> resp) => _discard(resp);

  void close() => dio.close(force: true);
}

FdamException mapDioError(DioException e, String url) {
  final where = redactUrl(url);
  switch (e.type) {
    case DioExceptionType.cancel:
      return FdamException(FdamErrorCode.cancelled, 'cancelled: $where');
    case DioExceptionType.connectionTimeout:
    case DioExceptionType.sendTimeout:
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.transformTimeout:
      return FdamException(FdamErrorCode.downloadInterrupted, 'timeout (${e.type.name}): $where', retryable: true);
    case DioExceptionType.connectionError:
      return FdamException(FdamErrorCode.networkUnavailable, 'connection error: $where (${e.error.runtimeType})',
          retryable: true);
    case DioExceptionType.badCertificate:
      return FdamException(FdamErrorCode.httpError, 'bad certificate: $where');
    case DioExceptionType.badResponse:
      final code = e.response?.statusCode;
      return FdamException(FdamErrorCode.httpError, 'HTTP $code: $where',
          httpStatus: code, retryable: code == null || code >= 500 || code == 429);
    case DioExceptionType.unknown:
      final inner = e.error;
      if (inner is SocketException || inner is HttpException || inner is TimeoutException) {
        return FdamException(FdamErrorCode.downloadInterrupted, '${inner.runtimeType}: $where', retryable: true);
      }
      return FdamException(FdamErrorCode.unknown, '${inner.runtimeType}: $where', retryable: true);
  }
}
