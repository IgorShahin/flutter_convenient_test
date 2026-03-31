import 'package:chuck_interceptor/chuck_interceptor.dart';
import 'package:convenient_test_dev/src/functions/dio_interceptor.dart';
import 'package:convenient_test_dev/src/functions/log.dart';
import 'package:dio/dio.dart';

/// Helper bundle that wires Chuck + convenient_test request logs together.
///
/// Usage:
/// ```dart
/// final bundle = createConvenientTestChuckBundle();
/// bundle.attachTo(dio);
/// ```
///
/// Then:
/// - In-app Chuck UI still works from [chuck]
/// - Test Manager "Requests" tab receives HTTP logs from [managerInterceptor]
class ConvenientTestChuckBundle {
  final Chuck chuck;
  final ChuckDioInterceptor _chuckInterceptor;
  final Interceptor _requestLogInterceptor;

  const ConvenientTestChuckBundle({
    required this.chuck,
    required ChuckDioInterceptor chuckInterceptor,
    required Interceptor requestLogInterceptor,
  })  : _chuckInterceptor = chuckInterceptor,
        _requestLogInterceptor = requestLogInterceptor;

  /// Native Chuck interceptor for the tested app.
  ChuckDioInterceptor get chuckInterceptor => _chuckInterceptor;

  /// convenient_test interceptor that forwards HTTP data to Test Manager.
  Interceptor get managerInterceptor => _requestLogInterceptor;

  /// Attach both interceptors with a single call.
  List<Interceptor> get interceptors => [chuckInterceptor, managerInterceptor];

  /// Alias for users who want a Dio-oriented API naming.
  List<Interceptor> get dioInterceptors => interceptors;

  void attachTo(Dio dio) {
    final hasChuck =
        dio.interceptors.any((i) => identical(i, chuckInterceptor));
    if (!hasChuck) dio.interceptors.add(chuckInterceptor);

    final hasRequestLogger =
        dio.interceptors.any((i) => identical(i, managerInterceptor));
    if (!hasRequestLogger) dio.interceptors.add(managerInterceptor);
  }
}

ConvenientTestChuckBundle createConvenientTestChuckBundle({
  Chuck? chuck,
  HttpLogOptions httpLogOptions = const HttpLogOptions(),
}) {
  final resolvedChuck = chuck ?? Chuck();
  return ConvenientTestChuckBundle(
    chuck: resolvedChuck,
    chuckInterceptor: resolvedChuck.dioInterceptor,
    requestLogInterceptor:
        ConvenientTestDioInterceptor(options: httpLogOptions),
  );
}
