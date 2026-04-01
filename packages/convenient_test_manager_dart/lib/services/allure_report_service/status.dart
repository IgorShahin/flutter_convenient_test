part of '../allure_report_service.dart';

String _formatStepName(LogSubEntry sub) {
  final title = sub.title.trim();
  final message = sub.message.trim();
  if (title.isEmpty) return message.isEmpty ? sub.type.name : message;
  if (message.isEmpty) return title;
  return '$title $message';
}

bool _isHiddenLifecycleStep(LogSubEntry sub) {
  final name = _formatStepName(sub).trim().toUpperCase();
  if (sub.type == LogSubEntryType.TEST_START ||
      sub.type == LogSubEntryType.TEST_END) {
    return true;
  }
  return name == 'START' || name == 'END';
}

String _statusForLogSubEntry(LogSubEntry sub) {
  if (sub.type == LogSubEntryType.ASSERT_FAIL) {
    return 'failed';
  }
  if (_isExceptionLikeLogSubEntry(sub)) {
    return _isAssertionLikeException(sub) ? 'failed' : 'broken';
  }
  return 'passed';
}

String _statusForRunnerError(RunnerError request) {
  final haystack = [request.error, request.stackTrace]
      .where((e) => e.trim().isNotEmpty)
      .join('\n')
      .toLowerCase();
  return _looksAssertionLikeText(haystack) ? 'failed' : 'broken';
}

bool _isExceptionLikeLogSubEntry(LogSubEntry sub) {
  return _looksLikeErrorTitle(sub.title) ||
      sub.error.isNotEmpty ||
      sub.stackTrace.isNotEmpty;
}

bool _looksLikeErrorTitle(String title) {
  final normalized = title.trim().toUpperCase();
  return normalized == 'ERROR' ||
      normalized.startsWith('ERROR ') ||
      normalized.startsWith('EXCEPTION');
}

bool _isAssertionLikeException(LogSubEntry sub) {
  final haystack = [sub.title, sub.message, sub.error, sub.stackTrace]
      .where((e) => e.trim().isNotEmpty)
      .join('\n')
      .toLowerCase();

  return _looksAssertionLikeText(haystack);
}

bool _looksAssertionLikeText(String haystack) {
  return haystack.contains('pixel test failed') ||
      haystack.contains('golden ') ||
      haystack.contains('test failed. see exception logs above.') ||
      haystack.contains('expected:') ||
      haystack.contains('matcher:') ||
      haystack.contains('which:');
}

bool _shouldSkipErrorLikeSubEntry(
  _AllureTestRuntime runtime,
  LogSubEntry sub,
) {
  final normalizedTitle = sub.title.trim().toUpperCase();
  if (normalizedTitle != 'ERROR' && normalizedTitle != 'EXCEPTION') {
    return false;
  }

  final haystack = [sub.title, sub.message, sub.error, sub.stackTrace]
      .where((e) => e.trim().isNotEmpty)
      .join('\n')
      .toLowerCase();
  if (!haystack.contains('test failed. see exception logs above.')) {
    return false;
  }

  return _hasDetailedErrorStep(runtime);
}

bool _shouldSkipRunnerErrorStep(
  _AllureTestRuntime runtime,
  RunnerError request,
) {
  if (!_hasDetailedErrorStep(runtime)) {
    return false;
  }
  return true;
}

bool _hasDetailedErrorStep(_AllureTestRuntime runtime) {
  bool hasDetailed(List<Map<String, dynamic>> steps) {
    for (final step in steps) {
      final stepName = ((step['name'] as String?) ?? '').trim().toUpperCase();
      final attachments =
          (step['attachments'] as List?)?.cast<Map<String, dynamic>>() ??
              const <Map<String, dynamic>>[];
      final hasExceptionAttachment =
          attachments.any((e) => e['name'] == 'exception');
      final statusDetails = step['statusDetails'] as Map<String, dynamic>?;
      final message = ((statusDetails?['message'] as String?) ?? '').trim();
      final trace = ((statusDetails?['trace'] as String?) ?? '').trim();
      if ((stepName == 'ERROR' || stepName == 'EXCEPTION') &&
          (hasExceptionAttachment || message.isNotEmpty || trace.isNotEmpty)) {
        return true;
      }
    }
    return false;
  }

  return hasDetailed(runtime.steps) ||
      runtime.beforeFixtures.values.any((e) => hasDetailed(e.steps)) ||
      runtime.afterFixtures.values.any((e) => hasDetailed(e.steps));
}

String _mergeRuntimeStatus({
  required String? current,
  required String incoming,
}) {
  if (current == null || current.isEmpty || current == 'unknown') {
    return incoming;
  }
  if (current == 'broken' || incoming == 'broken') {
    return 'broken';
  }
  if (current == 'failed' || incoming == 'failed') {
    return 'failed';
  }
  return current;
}

String _exceptionLikeMessage(LogSubEntry sub) {
  if (sub.error.trim().isNotEmpty) return sub.error;
  return sub.message;
}

String _exceptionLikeTrace(LogSubEntry sub) {
  if (sub.stackTrace.trim().isNotEmpty) return sub.stackTrace;
  return '';
}

bool _shouldInlineExceptionDetails({
  required String message,
  required String trace,
}) {
  final cleanMessage = message.trim();
  final cleanTrace = trace.trim();
  if (cleanMessage.isEmpty && cleanTrace.isEmpty) {
    return false;
  }
  if (cleanTrace.isNotEmpty) {
    return false;
  }

  final lineCount = '\n'.allMatches(cleanMessage).length + 1;
  if (lineCount > 3) {
    return false;
  }

  return cleanMessage.length <= 240;
}

String _allureStatusFromResult(String result) {
  switch (result) {
    case 'success':
      return 'passed';
    case 'failure':
      return 'failed';
    case 'skipped':
      return 'skipped';
    case 'error':
      return 'broken';
    default:
      return 'unknown';
  }
}

String _effectiveRuntimeStatus(_AllureTestRuntime runtime) {
  final current = runtime.status ?? 'unknown';
  final worstStepStatus = _worstStepStatus(runtime);
  if (worstStepStatus == null) {
    return current;
  }
  if (current == 'unknown' || current == 'passed') {
    return worstStepStatus;
  }
  if (current == 'broken' && worstStepStatus == 'failed') {
    return 'failed';
  }
  if (current == 'failed' && worstStepStatus == 'broken') {
    return 'broken';
  }
  return current;
}

bool _shouldIncludeRuntimeStatusDetails(_AllureTestRuntime runtime) {
  return runtime.statusDetails != null && !_hasDetailedErrorStep(runtime);
}

String? _errorSignature({
  required String message,
  required String trace,
}) {
  final normalizedMessage =
      message.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  final normalizedTrace =
      trace.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  if (normalizedMessage.isEmpty && normalizedTrace.isEmpty) {
    return null;
  }
  return '$normalizedMessage\n$normalizedTrace';
}

String? _worstStepStatus(_AllureTestRuntime runtime) {
  var hasFailed = false;

  bool collect(List<Map<String, dynamic>> steps) {
    for (final step in steps) {
      final status = ((step['status'] as String?) ?? '').trim().toLowerCase();
      if (status == 'broken') {
        return true;
      }
      if (status == 'failed') {
        hasFailed = true;
      }
    }
    return false;
  }

  if (collect(runtime.steps)) {
    return 'broken';
  }
  for (final fixture in runtime.beforeFixtures.values) {
    if (collect(fixture.steps)) {
      return 'broken';
    }
  }
  for (final fixture in runtime.afterFixtures.values) {
    if (collect(fixture.steps)) {
      return 'broken';
    }
  }
  return hasFailed ? 'failed' : null;
}

void _closeOpenAllureCustomSteps(_AllureTestRuntime runtime) {
  if (runtime.openAllureStepIds.isEmpty) return;
  final stopMs = runtime.stopMs;
  for (final stepId in runtime.openAllureStepIds.toList().reversed) {
    final step = runtime.allureStepsById[stepId];
    if (step == null) continue;
    final start = (step['start'] as int?) ?? stopMs;
    step['stop'] = max(start, stopMs);
  }
  runtime.openAllureStepIds.clear();
}
