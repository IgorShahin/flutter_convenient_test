import 'package:convenient_test_dev/src/functions/log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';

/// Alias over [setUp].
///
/// In isolation mode this runs before each executed test (as usual).
@isTest
void setUpPerTest(dynamic Function() body) {
  setUp(() async {
    convenientTestLog('SETUP', 'setUp');
    await Future.sync(body);
  });
}

/// Alias over [setUpAll].
///
/// Note: in isolation mode each worker run is restarted between tests, so this
/// executes once per worker run.
@isTest
void setUpOncePerRun(dynamic Function() body) {
  setUpAll(() async {
    convenientTestLog('SETUP', 'setUpAll');
    await Future.sync(body);
  });
}

/// Alias over [tearDown].
///
/// In isolation mode this runs after each executed test (as usual).
@isTest
void tearDownPerTest(dynamic Function() body) {
  tearDown(() async {
    convenientTestLog('TEARDOWN', 'tearDown');
    await Future.sync(body);
  });
}

/// Alias over [tearDownAll].
///
/// Note: in isolation mode each worker run is restarted between tests, so this
/// executes once per worker run.
@isTest
void tearDownOncePerRun(dynamic Function() body) {
  tearDownAll(() async {
    convenientTestLog('TEARDOWN', 'tearDownAll');
    await Future.sync(body);
  });
}
