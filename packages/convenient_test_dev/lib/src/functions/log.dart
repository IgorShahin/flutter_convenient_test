// ref: https://docs.cypress.io/api/cypress-api/cypress-log#Arguments

// ignore_for_file: implementation_imports
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convenient_test_common/convenient_test_common.dart';
import 'package:convenient_test_dev/src/functions/instance.dart';
import 'package:convenient_test_dev/src/support/reporter_service.dart';
import 'package:convenient_test_dev/src/support/static_config.dart';
import 'package:convenient_test_dev/src/utils/snapshot.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meta/meta.dart';
import 'package:test_api/src/backend/group.dart';
import 'package:test_api/src/backend/invoker.dart';
import 'package:test_api/src/backend/live_test.dart';

extension ConvenientTestLog on ConvenientTest {
  void section(String description) =>
      log('SECTION', description, type: LogSubEntryType.SECTION);

  // p.s. can search emoji here - https://emojipedia.org
  LogHandle log(String title, String message, {LogSubEntryType? type}) =>
      convenientTestLog(title, message, type: type);
}

LogHandle convenientTestLog(
  String title,
  String message, {
  LogSubEntryType? type,
  String? error,
  String? stackTrace,
  LiveTest? liveTest,
}) {
  final log = LogHandle.create(liveTest: liveTest);
  _updateActiveTestTracking(
      log._testName, type ?? LogSubEntryType.GENERAL_MESSAGE);

  log.update(
    title,
    message,
    type: type ?? LogSubEntryType.GENERAL_MESSAGE,
    error: error,
    stackTrace: stackTrace,
    initial: true,
    printing: true, // <--
  );

  return log;
}

final _activeConvenientTestNames = <String>{};
final _allureConsoleOpenStepIdsByTestName = <String, List<String>>{};
final _allureConsoleDepthByStepId = <String, int>{};
const _kTextAttachmentTitlePrefix = '__CT_TEXT_ATTACHMENT__:';
const _kAllureTagsPrefix = '__CT_ALLURE_TAGS__:';
const _kAllureStepStartPrefix = '__CT_ALLURE_STEP_START__:';
const _kAllureStepEndPrefix = '__CT_ALLURE_STEP_END__:';
const _kAllureStepParameterPrefix = '__CT_ALLURE_STEP_PARAMETER__:';
const _kAllureStepTextAttachmentPrefix = '__CT_ALLURE_STEP_TEXT_ATTACHMENT__:';
const _kAllureStepJsonAttachmentPrefix = '__CT_ALLURE_STEP_JSON_ATTACHMENT__:';

void _updateActiveTestTracking(String testName, LogSubEntryType type) {
  switch (type) {
    case LogSubEntryType.TEST_START:
      _activeConvenientTestNames.add(testName);
      return;
    case LogSubEntryType.TEST_END:
      _activeConvenientTestNames.remove(testName);
      final openStepIds = _allureConsoleOpenStepIdsByTestName.remove(testName);
      if (openStepIds != null) {
        for (final stepId in openStepIds) {
          _allureConsoleDepthByStepId.remove(stepId);
        }
      }
      return;
    default:
      return;
  }
}

bool get hasActiveConvenientTest => _activeConvenientTestNames.isNotEmpty;

typedef LogUpdate = void Function(
  String title,
  String message, {
  String? error,
  String? stackTrace,
  required LogSubEntryType type,
  bool printing,
});
typedef LogSnapshot = Future<void> Function({String name, List<int>? image});

class LogHandle {
  static const _kTag = 'LogHandle';

  final int _id;
  final String _testName;

  LogHandle._(this._id, this._testName);

  factory LogHandle.create({LiveTest? liveTest}) {
    return LogHandle._(
      IdGenerator.instance.nextId(),
      (liveTest ?? Invoker.current!.liveTest).test.name,
    );
  }

  Future<void> update(
    String title,
    String message, {
    String? error,
    String? stackTrace,
    LogSubEntryType type = LogSubEntryType.GENERAL_MESSAGE,
    bool printing = false,
    bool initial = false,
  }) async {
    if (printing) {
      Log.i(
        _kTag,
        '${_typeToLeading(type)} (#$_id, ${initial ? "create" : "update"}) $title $message $error $stackTrace',
      );
    }

    final reporterService = WorkerReportSaverService.I;
    if (reporterService != null) {
      await reporterService.report(
        ReportItem(
          logEntry: LogEntry(
            id: _id.toInt64(),
            testName: _testName,
            subEntries: [
              LogSubEntry(
                id: IdGenerator.instance.nextId().toInt64(),
                type: type,
                time: Int64(DateTime.now().microsecondsSinceEpoch),
                title: title,
                message: message,
                error: error,
                stackTrace: stackTrace,
              ),
            ],
          ),
        ),
      );
    }
  }

  Future<void> snapshot({String name = 'default', List<int>? image}) async {
    Future<List<int>> computeImage() async {
      final tester = ConvenientTest.maybeActiveInstance?.tester;
      return image ??
          await _maybeRunAsync(
            tester,
            () => takeSnapshot(pumper: tester?.pump),
          );
    }

    final reporterService = WorkerReportSaverService.I;
    if (reporterService != null) {
      await reporterService.report(
        ReportItem(
          snapshot: Snapshot(
            logEntryId: _id.toInt64(),
            name: name,
            image: await computeImage(),
          ),
        ),
      );
    } else {
      if (StaticConfig.kVerbose) {
        final briefTime = DateTime.now()
            .toLocal()
            .toIso8601String()
            .replaceAll(':', '')
            .replaceAll('.', '-');
        final filename =
            'convenient_test_debug_screenshots/debug_screenshot_${briefTime}_$name.png';
        File(filename).parent.createSync(recursive: true);
        File(filename).writeAsBytesSync(await computeImage());
        Log.i(_kTag, 'snapshot() saved file to disk at: $filename');
      } else {
        Log.i(
          _kTag,
          'snapshot() is no-op; specify `${StaticConfig.kVerboseKey}` to save screenshots to disk.',
        );
      }
    }
  }

  Future<void> attachText({
    required String name,
    required String content,
  }) async {
    await update(
      '$_kTextAttachmentTitlePrefix$name',
      content,
      printing: false,
    );
  }
}

Future<LogHandle> convenientTestLogWithTextAttachment(
  String title,
  String message, {
  required String attachmentName,
  required String attachmentContent,
  LogSubEntryType? type,
  String? error,
  String? stackTrace,
  LiveTest? liveTest,
}) async {
  final log = convenientTestLog(
    title,
    message,
    type: type,
    error: error,
    stackTrace: stackTrace,
    liveTest: liveTest,
  );
  await log.attachText(
    name: attachmentName,
    content: attachmentContent,
  );
  return log;
}

Future<void> convenientTestAddAllureTags(
  Iterable<String> tags, {
  LiveTest? liveTest,
}) async {
  final normalized = tags
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet()
      .toList(growable: false);
  if (normalized.isEmpty) return;

  final reporterService = WorkerReportSaverService.I;
  if (reporterService == null) return;

  Log.i(
    LogHandle._kTag,
    '🟣 ALLURE TAGS ${normalized.join(', ')}',
  );

  final testName = (liveTest ?? Invoker.current!.liveTest).test.name;
  await reporterService.report(
    ReportItem(
      runnerMessage: RunnerMessage(
        testName: testName,
        message: '$_kAllureTagsPrefix${jsonEncode(normalized)}',
      ),
    ),
  );
}

class AllureStepHandle {
  final String _id;
  final String _testName;
  final String _name;

  const AllureStepHandle._(this._id, this._testName, this._name);

  Future<void> parameter(String name, Object? value) async {
    final valueText = _shortConsoleValue(value?.toString() ?? '');
    Log.i(
      LogHandle._kTag,
      '${_allureConsoleIndentForStep(_id, extraDepth: 1)}🔹 $name: $valueText',
    );
    await _reportRunnerMessage(
      _testName,
      '$_kAllureStepParameterPrefix${jsonEncode({
            'id': _id,
            'name': name,
            'value': value?.toString() ?? '',
          })}',
    );
  }

  Future<void> attachText({
    required String name,
    required String content,
  }) async {
    final indent = _allureConsoleIndentForStep(_id, extraDepth: 1);
    final body = _attachmentConsoleBody(content, indent: '$indent  ');
    Log.i(
      LogHandle._kTag,
      '$indent📎 $name [text, ${content.length} chars]$body',
    );
    await _reportRunnerMessage(
      _testName,
      '$_kAllureStepTextAttachmentPrefix${jsonEncode({
            'id': _id,
            'name': name,
            'content': content,
          })}',
    );
  }

  Future<void> attachJson({
    required String name,
    required Object? value,
  }) async {
    final content = const JsonEncoder.withIndent('  ').convert(value);
    final indent = _allureConsoleIndentForStep(_id, extraDepth: 1);
    final body = _attachmentConsoleBody(content, indent: '$indent  ');
    Log.i(
      LogHandle._kTag,
      '$indent📎 $name [json, ${content.length} chars]$body',
    );
    await _reportRunnerMessage(
      _testName,
      '$_kAllureStepJsonAttachmentPrefix${jsonEncode({
            'id': _id,
            'name': name,
            'content': content,
          })}',
    );
  }

  Future<T> step<T>(
    String name,
    FutureOr<T> Function(AllureStepHandle step) body,
  ) {
    return convenientTestAllureStep(
      name,
      body: body,
      liveTest: _currentLiveTestByName(_testName),
    );
  }

  Future<void> end({String status = 'passed'}) async {
    final indent = _allureConsoleIndentForStep(_id);
    Log.i(
      LogHandle._kTag,
      '$indent${_allureStatusIcon(status)} ${_shortConsoleValue(_name)}',
    );
    _allureConsolePopStep(_testName, _id);
    await _reportRunnerMessage(
      _testName,
      '$_kAllureStepEndPrefix${jsonEncode({
            'id': _id,
            'status': status,
          })}',
    );
  }
}

Future<AllureStepHandle> convenientTestOpenAllureStep(
  String name, {
  LiveTest? liveTest,
}) async {
  final testName = _liveTestName(liveTest);
  final id = IdGenerator.instance.nextId().toString();
  final depth = _allureConsolePushStep(testName, id);
  final indent = _allureConsoleIndent(depth);
  Log.i(
    LogHandle._kTag,
    '$indent▶️ ${_shortConsoleValue(name)}',
  );
  await _reportRunnerMessage(
    testName,
    '$_kAllureStepStartPrefix${jsonEncode({
          'id': id,
          'name': name,
        })}',
  );
  return AllureStepHandle._(id, testName, name);
}

Future<T> convenientTestAllureStep<T>(
  String name, {
  required FutureOr<T> Function(AllureStepHandle step) body,
  LiveTest? liveTest,
}) async {
  final step = await convenientTestOpenAllureStep(name, liveTest: liveTest);
  try {
    final result = await Future<T>.value(body(step));
    await step.end(status: 'passed');
    return result;
  } catch (error, stackTrace) {
    await step.attachText(
      name: 'exception',
      content: [
        error.toString().trim(),
        stackTrace.toString().trim(),
      ].where((e) => e.isNotEmpty).join('\n\n'),
    );
    await step.end(status: _allureStatusForThrown(error, stackTrace));
    rethrow;
  }
}

String _allureStatusForThrown(Object error, StackTrace stackTrace) {
  if (error is TestFailure) {
    return 'failed';
  }
  final haystack = '$error\n$stackTrace'.toLowerCase();
  if (haystack.contains('pixel test failed') ||
      haystack.contains('golden ') ||
      haystack.contains('test failed. see exception logs above.') ||
      haystack.contains('expected:') ||
      haystack.contains('matcher:') ||
      haystack.contains('which:')) {
    return 'failed';
  }
  return 'broken';
}

String _liveTestName(LiveTest? liveTest) =>
    (liveTest ?? Invoker.current!.liveTest).test.name;

LiveTest? _currentLiveTestByName(String testName) {
  try {
    final current = Invoker.current!.liveTest;
    if (current.test.name == testName) {
      return current;
    }
  } catch (_) {}
  return null;
}

Future<void> _reportRunnerMessage(String testName, String message) async {
  final reporterService = WorkerReportSaverService.I;
  if (reporterService == null) return;

  await reporterService.report(
    ReportItem(
      runnerMessage: RunnerMessage(
        testName: testName,
        message: message,
      ),
    ),
  );
}

String _shortConsoleValue(String value, {int maxChars = 160}) {
  final singleLine = value.replaceAll('\n', r'\n').trim();
  if (singleLine.length <= maxChars) return singleLine;
  return '${singleLine.substring(0, maxChars)}...';
}

String _attachmentConsoleBody(
  String content, {
  required String indent,
}) {
  final trimmed = content.trimRight();
  if (trimmed.isEmpty) return '';
  final formatted =
      trimmed.split('\n').map((line) => '$indent$line').join('\n');
  return '\n$formatted';
}

int _allureConsolePushStep(String testName, String stepId) {
  final openSteps = _allureConsoleOpenStepIdsByTestName.putIfAbsent(
    testName,
    () => <String>[],
  );
  final depth = openSteps.length;
  openSteps.add(stepId);
  _allureConsoleDepthByStepId[stepId] = depth;
  return depth;
}

void _allureConsolePopStep(String testName, String stepId) {
  final openSteps = _allureConsoleOpenStepIdsByTestName[testName];
  if (openSteps != null) {
    openSteps.remove(stepId);
    if (openSteps.isEmpty) {
      _allureConsoleOpenStepIdsByTestName.remove(testName);
    }
  }
  _allureConsoleDepthByStepId.remove(stepId);
}

String _allureConsoleIndentForStep(String stepId, {int extraDepth = 0}) {
  final depth = (_allureConsoleDepthByStepId[stepId] ?? 0) + extraDepth;
  return _allureConsoleIndent(depth);
}

String _allureConsoleIndent(int depth) => '  ' * depth;

String _allureStatusIcon(String status) {
  switch (status.trim().toLowerCase()) {
    case 'passed':
      return '✅';
    case 'failed':
      return '❌';
    case 'broken':
      return '🚫';
    case 'skipped':
      return '⏭️';
    default:
      return '🟣';
  }
}

Future<T> _maybeRunAsync<T extends Object>(
  WidgetTester? tester,
  Future<T> Function() f,
) async {
  if (tester == null) return await f();
  return (await tester.runAsync(f))!;
}

String _typeToLeading(LogSubEntryType type) {
  switch (type) {
    case LogSubEntryType.TEST_START:
    case LogSubEntryType.TEST_END:
      return '🟤';
    case LogSubEntryType.GENERAL_MESSAGE:
    default:
      return '🔵';
  }
}

String testGroupsToName(List<Group> testGroups) {
  return testGroups //
      .map((g) => g.name)
      .where((name) => name.isNotEmpty)
      .join('-');
}

// /// https://stackoverflow.com/questions/49138971/logging-large-strings-from-flutter
// void printWrapped(String text) {
//   final pattern = RegExp('.{1,800}'); // 800 is the size of each chunk
//   pattern.allMatches(text).forEach((match) => print(match.group(0))); // ignore: avoid_print
// }

@internal
void setUpLogTestStartAndEnd() {
  setUp(() {
    convenientTestLog('START', '', type: LogSubEntryType.TEST_START);
  });
  tearDown(() {
    convenientTestLog('END', '', type: LogSubEntryType.TEST_END);
  });
}

const _kDefaultSensitiveKeys = <String>{
  'authorization',
  'proxy-authorization',
  'x-token',
  'x-api-key',
  'api-key',
  'access_token',
  'refresh_token',
  'token',
  'password',
  'passwd',
  'secret',
  'cookie',
  'set-cookie',
};

class HttpLogOptions {
  final bool enabled;
  final bool includeHeaders;
  final bool includeBody;
  final int maxBodyChars;
  final Set<String> sensitiveKeys;

  const HttpLogOptions({
    this.enabled = true,
    this.includeHeaders = true,
    this.includeBody = true,
    this.maxBodyChars = 8000,
    this.sensitiveKeys = _kDefaultSensitiveKeys,
  });
}

Future<void> convenientTestLogHttpRequest({
  required String method,
  required String path,
  int? requestId,
  Object? headers,
  Object? body,
  HttpLogOptions options = const HttpLogOptions(),
}) async {
  if (!options.enabled) return;
  final idPart = requestId == null ? '' : ' #$requestId';
  final log = convenientTestLog('HTTP$idPart ➡️  $method $path', '');
  final message = _buildHttpMessage(
    headers: headers,
    body: body,
    options: options,
  );
  if (message.isNotEmpty) {
    await log.update('HTTP$idPart body', message);
  }
}

Future<void> convenientTestLogHttpResponse({
  required String method,
  required String path,
  required int statusCode,
  int? requestId,
  Duration? latency,
  Object? headers,
  Object? body,
  HttpLogOptions options = const HttpLogOptions(),
}) async {
  if (!options.enabled) return;
  final idPart = requestId == null ? '' : ' #$requestId';
  final latencyPart = latency == null ? '' : ' (${latency.inMilliseconds}ms)';
  final log = convenientTestLog(
    'HTTP$idPart ⬅️  $statusCode $method $path$latencyPart',
    '',
  );
  final message = _buildHttpMessage(
    headers: headers,
    body: body,
    options: options,
  );
  if (message.isNotEmpty) {
    await log.update('HTTP$idPart resp', message);
  }
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
