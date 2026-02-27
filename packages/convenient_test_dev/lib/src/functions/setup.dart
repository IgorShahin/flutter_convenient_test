import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:convenient_test_dev/src/functions/log.dart';
import 'package:convenient_test_dev/src/support/static_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';

/// Alias over [setUp].
///
/// In isolation mode this runs before each executed test (as usual).
@isTest
void setUpPerTest(dynamic Function() body) {
  setUp(() async {
    // convenientTestLog('SETUP', '');
    await Future.sync(body);
  });
}

/// Alias over [setUpAll].
///
/// In isolation mode this executes once per entire super-run.
@isTest
void setUpOncePerRun(dynamic Function() body) {
  final registrationIndex = _nextSetUpOncePerRunRegistrationIndex++;
  setUpAll(() async {
    final shouldExecute = await _claimOncePerSuperRun(
      'setup-$registrationIndex',
    );
    if (!shouldExecute) return;

    convenientTestLog('SETUP_ALL', '');
    await Future.sync(body);
  });
}

/// Alias over [tearDown].
///
/// In isolation mode this runs after each executed test (as usual).
@isTest
void tearDownPerTest(dynamic Function() body) {
  tearDown(() async {
    // convenientTestLog('TEARDOWN', '');
    await Future.sync(body);
  });
}

/// Alias over [tearDownAll].
///
/// In isolation mode this executes once per entire super-run.
@isTest
void tearDownOncePerRun(dynamic Function() body) {
  final registrationIndex = _nextTearDownOncePerRunRegistrationIndex++;
  tearDownAll(() async {
    final shouldExecute = await _claimOncePerSuperRun(
      'teardown-$registrationIndex',
    );
    if (!shouldExecute) return;

    // convenientTestLog('TEARDOWN_ALL', '');
    await Future.sync(body);
  });
}

/// Must be called at the beginning of each worker run.
///
/// When [isFirstRunInSuperRun] is true, this resets once-per-run markers so
/// [setUpOncePerRun]/[tearDownOncePerRun] execute exactly once for that
/// super-run, even across hot restarts.
@internal
Future<void> prepareSetupOncePerRunSession({
  required bool isFirstRunInSuperRun,
}) async {
  if (!isFirstRunInSuperRun) return;

  final projectDir = await _projectLifecycleDir();
  if (projectDir.existsSync()) {
    await projectDir.delete(recursive: true);
  }
  await projectDir.create(recursive: true);

  final markersDir = await _markersDir();
  await markersDir.create(recursive: true);

  final token = '${DateTime.now().toUtc().microsecondsSinceEpoch}'
      '_${Random().nextInt(1 << 32).toRadixString(16)}';
  await (await _sessionFile()).writeAsString(token, flush: true);
}

Future<bool> _claimOncePerSuperRun(String key) async {
  final markersDir = await _markersDir();
  await markersDir.create(recursive: true);

  final session = await _readSessionToken();
  final markerFile = File('${markersDir.path}/$session-$key.marker');
  if (await markerFile.exists()) return false;

  await markerFile.writeAsString('1', flush: true);
  return true;
}

Future<String> _readSessionToken() async {
  final file = await _sessionFile();
  if (await file.exists()) {
    final content = (await file.readAsString()).trim();
    if (content.isNotEmpty) return content;
  }
  // Fallback: if session was not initialized for some reason, keep behavior
  // deterministic and still allow once-per-run semantics for current process.
  const fallback = 'legacy';
  await file.parent.create(recursive: true);
  await file.writeAsString(fallback, flush: true);
  return fallback;
}

Future<File> _sessionFile() async =>
    File('${(await _projectLifecycleDir()).path}/session.txt');

Future<Directory> _markersDir() async =>
    Directory('${(await _projectLifecycleDir()).path}/markers');

Future<Directory> _projectLifecycleDir() async {
  final appCodeDir = StaticConfig.kAppCodeDir;
  final encoded = base64Url.encode(utf8.encode(appCodeDir)).replaceAll('=', '');
  return Directory(
      '${Directory.systemTemp.path}/convenient_test_once_per_run/$encoded');
}

int _nextSetUpOncePerRunRegistrationIndex = 0;
int _nextTearDownOncePerRunRegistrationIndex = 0;
