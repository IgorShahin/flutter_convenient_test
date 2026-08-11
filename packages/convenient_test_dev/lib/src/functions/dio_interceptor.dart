import 'dart:async';
import 'dart:convert';

import 'package:convenient_test_dev/src/functions/log.dart';
import 'package:dio/dio.dart';

/// Logs Dio network traffic into convenient_test manager's right log panel.
///
/// Attach from the tested project:
/// `dio.interceptors.add(ConvenientTestDioInterceptor())`.
class ConvenientTestDioInterceptor extends Interceptor {
  ConvenientTestDioInterceptor({
    this.options = const HttpLogOptions(),
  });

  static const _kReqIdExtra = '__convenient_test_http_req_id__';
  static const _kReqStartedAtExtra = '__convenient_test_http_started_at__';
  static const _kReqLogHandleExtra = '__convenient_test_http_log_handle__';
  static const _kReqTrackedExtra = '__convenient_test_http_tracked__';

  final HttpLogOptions options;
  int _nextRequestId = 1;

  @override
  void onRequest(
      RequestOptions requestOptions, RequestInterceptorHandler handler) {
    handler.next(requestOptions);
    if (!options.enabled || !hasActiveConvenientTest) {
      requestOptions.extra[_kReqTrackedExtra] = false;
      return;
    }
    requestOptions.extra[_kReqTrackedExtra] = true;
    unawaited(_logRequest(requestOptions));
  }

  @override
  void onResponse(
      Response<dynamic> response, ResponseInterceptorHandler handler) {
    handler.next(response);
    if (!options.enabled ||
        response.requestOptions.extra[_kReqTrackedExtra] != true) {
      return;
    }
    unawaited(_logResponse(response));
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.next(err);
    if (!options.enabled ||
        err.requestOptions.extra[_kReqTrackedExtra] != true) {
      return;
    }
    unawaited(_logError(err));
  }

  Future<void> _logRequest(RequestOptions requestOptions) async {
    final reqId = _nextRequestId++;
    final startedAt = DateTime.now();
    requestOptions.extra[_kReqIdExtra] = reqId;
    requestOptions.extra[_kReqStartedAtExtra] = startedAt;

    final path = _formatPath(requestOptions.uri);
    final method = requestOptions.method.toUpperCase();
    final idPart = ' #$reqId';
    final log = convenientTestLog('HTTP$idPart ➡️  $method $path', '');
    requestOptions.extra[_kReqLogHandleExtra] = log;

    final message = _buildHttpMessage(
      headers: requestOptions.headers,
      body: requestOptions.data,
      options: options,
    );
    if (message.isNotEmpty) {
      await log.update('HTTP$idPart body', message);
    }
  }

  Future<void> _logResponse(Response<dynamic> response) async {
    final req = response.requestOptions;
    final reqId = req.extra[_kReqIdExtra] as int?;
    final idPart = reqId == null ? '' : ' #$reqId';
    final path = _formatPath(req.uri);
    final method = req.method.toUpperCase();
    final statusCode = response.statusCode ?? -1;
    final startedAt = req.extra[_kReqStartedAtExtra] as DateTime?;
    final latency =
        startedAt == null ? null : DateTime.now().difference(startedAt);
    final latencyPart = latency == null ? '' : ' (${latency.inMilliseconds}ms)';

    final log = req.extra[_kReqLogHandleExtra] as LogHandle? ??
        convenientTestLog(
          'HTTP$idPart ⬅️  $statusCode $method $path$latencyPart',
          '',
        );
    await log.update(
      'HTTP$idPart ⬅️  $statusCode $method $path$latencyPart',
      '',
    );

    final message = _buildHttpMessage(
      headers: response.headers.map,
      body: response.data,
      options: options,
    );
    if (message.isNotEmpty) {
      await log.update('HTTP$idPart resp', message);
    }
  }

  Future<void> _logError(DioException err) async {
    final req = err.requestOptions;
    final reqId = req.extra[_kReqIdExtra] as int?;
    final idPart = reqId == null ? '' : ' #$reqId';
    final path = _formatPath(req.uri);
    final method = req.method.toUpperCase();
    final statusCode = err.response?.statusCode;
    final startedAt = req.extra[_kReqStartedAtExtra] as DateTime?;
    final latency =
        startedAt == null ? null : DateTime.now().difference(startedAt);
    final latencyPart = latency == null ? '' : ' (${latency.inMilliseconds}ms)';
    final errorKind = _formatDioErrorKind(err.type);
    final statusPart =
        statusCode == null ? '$errorKind ERROR' : '$statusCode ERROR';

    final log = req.extra[_kReqLogHandleExtra] as LogHandle? ??
        convenientTestLog(
            'HTTP$idPart ⬅️  $statusPart $method $path$latencyPart', '');
    await log.update(
        'HTTP$idPart ⬅️  $statusPart $method $path$latencyPart', '');

    final chunks = <String>[
      'type: ${err.type.name}',
      if (err.message?.trim().isNotEmpty == true) 'error: ${err.message}',
      _buildHttpMessage(
        headers: err.response?.headers.map,
        body: err.response?.data,
        options: options,
      ),
    ].where((e) => e.trim().isNotEmpty).toList();
    if (chunks.isNotEmpty) {
      await log.update('HTTP$idPart error', chunks.join('\n'));
    }
  }
}

/// Convenience factory for work projects.
///
/// Usage:
/// `dio.interceptors.add(createConvenientTestManagerInterceptor())`
Interceptor createConvenientTestManagerInterceptor({
  HttpLogOptions options = const HttpLogOptions(),
}) {
  return ConvenientTestDioInterceptor(options: options);
}

String _formatPath(Uri uri) {
  final path = uri.path.isEmpty ? '/' : uri.path;
  final query = uri.hasQuery ? '?${uri.query}' : '';
  return '$path$query';
}

String _buildHttpMessage({
  required Object? headers,
  required Object? body,
  required HttpLogOptions options,
}) {
  final chunks = <String>[];
  if (options.includeHeaders && headers != null) {
    chunks.add('headers: ${_stringifyMasked(headers, options)}');
  }
  if (options.includeBody && body != null) {
    chunks.add('body: ${_stringifyMasked(body, options)}');
  }
  return chunks.join('\n');
}

String _stringifyMasked(Object value, HttpLogOptions options) {
  final masked = _maskSensitive(value, options.sensitiveKeys);
  String text;
  try {
    if (masked is String) {
      text = masked;
    } else {
      text = const JsonEncoder.withIndent('  ').convert(masked);
    }
  } catch (_) {
    text = masked.toString();
  }
  if (text.length <= options.maxBodyChars) return text;
  return '${text.substring(0, options.maxBodyChars)}...<truncated>';
}

Object _maskSensitive(Object? value, Set<String> sensitiveKeys) {
  if (value == null) return 'null';
  if (value is Map) {
    final out = <String, Object?>{};
    value.forEach((k, v) {
      final key = k.toString();
      final lower = key.toLowerCase();
      if (sensitiveKeys.contains(lower)) {
        out[key] = '***';
      } else {
        out[key] = _maskSensitive(v, sensitiveKeys);
      }
    });
    return out;
  }
  if (value is Iterable) {
    return value.map((e) => _maskSensitive(e, sensitiveKeys)).toList();
  }
  if (value is String) {
    if (value.length > 5 * 1024) {
      return '${value.substring(0, 5 * 1024)}...<truncated>';
    }
    return value;
  }
  return value.toString();
}

String _formatDioErrorKind(DioExceptionType type) {
  switch (type) {
    case DioExceptionType.cancel:
      return 'CANCELLED';
    case DioExceptionType.connectionTimeout:
      return 'CONNECTION_TIMEOUT';
    case DioExceptionType.sendTimeout:
      return 'SEND_TIMEOUT';
    case DioExceptionType.receiveTimeout:
      return 'RECEIVE_TIMEOUT';
    case DioExceptionType.badCertificate:
      return 'BAD_CERTIFICATE';
    case DioExceptionType.badResponse:
      return 'BAD_RESPONSE';
    case DioExceptionType.connectionError:
      return 'CONNECTION_ERROR';
    case DioExceptionType.unknown:
      return 'UNKNOWN';
    default:
      // Dio may add exception kinds without a major release. Keep logging
      // compatible with both the oldest supported and the latest Dio version.
      return type.name
          .replaceAllMapped(RegExp('[A-Z]'), (match) => '_${match[0]}')
          .toUpperCase();
  }
}
