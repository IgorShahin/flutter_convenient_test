import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/misc/runtime_platform.dart';
import 'package:convenient_test_manager_dart/services/fs_service.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:get_it/get_it.dart';

class ManagerAllureReportService {
  static const _kTag = 'ManagerAllureReportService';
  static const _kVideoChunkSnapshotPrefix = '__ct_video_chunk__';
  static const _kAutoPublishEnabledEnvKey =
      'CONVENIENT_TEST_ALLURE_DOCKER_AUTO_PUBLISH';
  static const _kAutoPublishApiBaseUrlEnvKey =
      'CONVENIENT_TEST_ALLURE_DOCKER_API_BASE_URL';
  static const _kAutoPublishProjectIdEnvKey =
      'CONVENIENT_TEST_ALLURE_DOCKER_PROJECT_ID';
  static const _kDefaultDockerApiBaseUrl =
      'http://localhost:5050/allure-docker-service';
  static const _kDefaultProjectId = 'default';
  static const _kConfigEnableKey = 'enableAllureDockerAutoPublish';
  static const _kConfigApiBaseUrlKey = 'allureDockerApiBaseUrl';
  static const _kConfigProjectIdKey = 'allureDockerProjectId';

  Future<void> save(ReportCollection request) async {
    if (!supportsIoPlatform) return;

    await _ensureActiveRunContext();
    if (_resultsDirPath == null) return;

    for (final item in request.items) {
      await _handleItem(item);
    }
  }

  Future<void> clear() async {
    if (!supportsIoPlatform) return;
    await _ensureActiveRunContext();
    await _clearAllureResults();
  }

  Future<void> generateAndOpenSite() async {
    if (!supportsIoPlatform) {
      Log.w(_kTag, 'generateAndOpenSite skipped on non-io runtime');
      return;
    }

    final settings = await _resolveAutoPublishSettings();
    final latestReportUri = _buildApiUri(
      settings.apiBaseUrl,
      '/latest-report',
      projectId: settings.projectId,
    );

    final reportUrl = latestReportUri.toString();
    final started = await _openUrlDetached(reportUrl);
    if (!started) return;
    Log.i(_kTag, 'remote allure report opened url=$reportUrl');
  }

  Future<void> autoPublishToDockerIfConfigured() async {
    if (!supportsIoPlatform) return;

    final settings = await _resolveAutoPublishSettings();
    if (!settings.enabled) return;

    final superRunId =
        GetIt.I.get<WorkerSuperRunStore>().currSuperRunController.superRunId;
    if (_lastAutoPublishedSuperRunId == superRunId) return;
    if (_autoPublishInProgress) return;

    _autoPublishInProgress = true;
    try {
      await _ensureActiveRunContext();
      final sourceResultsDir = _resultsDirPath;
      if (sourceResultsDir == null) return;

      final hasResults = Directory(sourceResultsDir)
          .listSync()
          .whereType<File>()
          .any((f) => f.path.endsWith('-result.json'));
      if (!hasResults) {
        Log.i(_kTag, 'auto-publish skip: no non-service allure result files');
        return;
      }

      final cleanUri = _buildApiUri(
        settings.apiBaseUrl,
        '/clean-results',
        projectId: settings.projectId,
      );
      final cleanStatus = await _httpGetStatus(cleanUri.toString());
      if (cleanStatus < 200 || cleanStatus >= 300) {
        Log.w(
          _kTag,
          'auto-publish clean-results returned status=$cleanStatus uri=$cleanUri',
        );
      }

      final sendStatus = await _sendResultsToAllureDocker(
        sourceDirPath: sourceResultsDir,
        apiBaseUrl: settings.apiBaseUrl,
        projectId: settings.projectId,
      );
      if (sendStatus < 200 || sendStatus >= 300) {
        Log.w(
          _kTag,
          'auto-publish send-results returned status=$sendStatus',
        );
        return;
      }

      final generateUri = _buildApiUri(
        settings.apiBaseUrl,
        '/generate-report',
        projectId: settings.projectId,
      );
      final responseCode = await _httpGetStatus(generateUri.toString());
      if (responseCode < 200 || responseCode >= 300) {
        Log.w(
          _kTag,
          'auto-publish generate-report returned status=$responseCode uri=$generateUri',
        );
        return;
      }

      _lastAutoPublishedSuperRunId = superRunId;
      Log.i(
        _kTag,
        'auto-publish success superRunId=$superRunId '
        'projectId=${settings.projectId} '
        'reportUrl=${_buildApiUri(settings.apiBaseUrl, '/latest-report', projectId: settings.projectId)} '
        'source=$sourceResultsDir',
      );
    } catch (e, s) {
      Log.w(_kTag, 'auto-publish failed e=$e s=$s');
    } finally {
      _autoPublishInProgress = false;
    }
  }

  Future<void> _handleItem(ReportItem item) async {
    switch (item.whichSubType()) {
      case ReportItem_SubType.suiteInfoProto:
        _suiteInfo = SuiteInfo.fromProto(item.suiteInfoProto);
        await _clearAllureResults();
        return;
      case ReportItem_SubType.logEntry:
        _handleLogEntry(item.logEntry);
        return;
      case ReportItem_SubType.runnerStateChange:
        await _handleRunnerStateChange(item.runnerStateChange);
        return;
      case ReportItem_SubType.runnerError:
        _handleRunnerError(item.runnerError);
        return;
      case ReportItem_SubType.runnerMessage:
        _handleRunnerMessage(item.runnerMessage);
        return;
      case ReportItem_SubType.snapshot:
        await _handleSnapshot(item.snapshot);
        return;
      case ReportItem_SubType.setUpAll:
      case ReportItem_SubType.tearDownAll:
      case ReportItem_SubType.notSet:
        return;
    }
  }

  void _handleLogEntry(LogEntry request) {
    final logEntryId = request.id.toInt();
    _testNameByLogEntryId[logEntryId] = request.testName;
    if (_isSetUpAllServiceTestName(request.testName)) {
      _runtimeUuidByLogEntryId.remove(logEntryId);
      _deferredSetUpAllLastStepIndexByLogEntryId.remove(logEntryId);
      for (final sub in request.subEntries) {
        final subMs = _usToMs(sub.time.toInt());
        final step = _buildStep(sub, subMs);
        final stepIndex = _deferredSetUpAllSteps.length;
        _deferredSetUpAllSteps.add(step);
        _deferredSetUpAllLastStepIndexByLogEntryId[logEntryId] = stepIndex;
        _deferredSetUpAllLogBuffer.writeln(_formatRawLogLine(sub, subMs));
      }
      _drainPendingSnapshots(logEntryId, request.testName);
      return;
    }
    if (_isServiceTestName(request.testName)) return;

    final runtime = _ensureActiveRuntime(request.testName);
    _runtimeUuidByLogEntryId[logEntryId] = runtime.uuid;
    _lastStepIndexByLogEntryId.remove(logEntryId);

    for (final sub in request.subEntries) {
      final subMs = _usToMs(sub.time.toInt());
      runtime.touchAt(subMs);

      final stepIndex = runtime.steps.length;
      runtime.steps.add(_buildStep(sub, subMs));
      _lastStepIndexByLogEntryId[logEntryId] = stepIndex;
      runtime.logBuffer.writeln(_formatRawLogLine(sub, subMs));
    }

    _drainPendingSnapshots(logEntryId, request.testName);
  }

  Future<void> _handleRunnerStateChange(RunnerStateChange request) async {
    if (_isServiceTestName(request.testName)) return;

    final runtime = _ensureActiveRuntime(request.testName);

    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    runtime.touchAt(nowMs);
    runtime.status = _allureStatusFromResult(request.state.result);

    if (request.state.status == 'complete') {
      await _finalize(runtime);
    }
  }

  void _handleRunnerError(RunnerError request) {
    if (_isSetUpAllServiceTestName(request.testName)) {
      _deferredSetUpAllLogBuffer.writeln('RUNNER ERROR: ${request.error}');
      if (request.stackTrace.isNotEmpty) {
        _deferredSetUpAllLogBuffer.writeln(request.stackTrace);
      }
      return;
    }
    if (_isServiceTestName(request.testName)) return;

    final runtime = _ensureActiveRuntime(request.testName);
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    runtime.touchAt(nowMs);
    runtime.status = runtime.status == 'failed' ? 'failed' : 'broken';
    runtime.statusDetails = {
      'message': request.error,
      'trace': request.stackTrace,
    };
    runtime.logBuffer.writeln('RUNNER ERROR: ${request.error}');
    if (request.stackTrace.isNotEmpty) {
      runtime.logBuffer.writeln(request.stackTrace);
    }
  }

  void _handleRunnerMessage(RunnerMessage request) {
    if (_isSetUpAllServiceTestName(request.testName)) {
      _deferredSetUpAllLogBuffer.writeln('RUNNER MESSAGE: ${request.message}');
      return;
    }
    if (_isServiceTestName(request.testName)) return;

    final runtime = _ensureActiveRuntime(request.testName);
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    runtime.touchAt(nowMs);
    runtime.logBuffer.writeln('RUNNER MESSAGE: ${request.message}');
  }

  Future<void> _handleSnapshot(Snapshot request) async {
    if (request.name.startsWith('$_kVideoChunkSnapshotPrefix:')) return;

    final logEntryId = request.logEntryId.toInt();
    final testName = _testNameByLogEntryId[logEntryId];
    if (testName == null) {
      (_pendingSnapshotsByLogEntryId[logEntryId] ??= []).add(
        _PendingSnapshot(name: request.name, image: request.image as Uint8List),
      );
      return;
    }
    if (_isSetUpAllServiceTestName(testName)) {
      final deferredStepIndex =
          _deferredSetUpAllLastStepIndexByLogEntryId[logEntryId];
      if (deferredStepIndex == null) {
        _deferredSetUpAllAttachments.add(_PendingSnapshot(
            name: request.name, image: request.image as Uint8List));
      } else {
        _attachSnapshotToStep(
          steps: _deferredSetUpAllSteps,
          stepIndex: deferredStepIndex,
          snapshotName: 'setUpAll:${request.name}',
          bytes: request.image as Uint8List,
        );
      }
      return;
    }
    if (_isServiceTestName(testName)) return;

    final runtime = _runtimeByLogEntryId(logEntryId) ??
        _activeRuntimeByTestName[testName] ??
        _ensureActiveRuntime(testName);
    final stepIndex = _lastStepIndexByLogEntryId[logEntryId];
    if (stepIndex == null || runtime.finished) {
      _attachSnapshotToRuntime(
          runtime, request.name, request.image as Uint8List);
    } else {
      _attachSnapshotToStep(
        steps: runtime.steps,
        stepIndex: stepIndex,
        snapshotName: request.name,
        bytes: request.image as Uint8List,
      );
    }
  }

  void _attachSnapshotToRuntime(
    _AllureTestRuntime runtime,
    String snapshotName,
    Uint8List bytes,
  ) {
    if (_resultsDirPath == null) return;
    final extension = _detectImageExtension(bytes);
    final source = _nextArtifactName('attachment', extension);
    final path = '$_resultsDirPath$source';
    File(path).writeAsBytesSync(bytes, flush: true);

    runtime.attachments.add({
      'name': snapshotName.isEmpty ? 'snapshot' : snapshotName,
      'source': source,
      'type': _mimeTypeForExtension(extension),
    });
  }

  void _attachSnapshotToStep({
    required List<Map<String, dynamic>> steps,
    required int stepIndex,
    required String snapshotName,
    required Uint8List bytes,
  }) {
    if (stepIndex < 0 || stepIndex >= steps.length) return;
    if (_resultsDirPath == null) return;

    final extension = _detectImageExtension(bytes);
    final source = _nextArtifactName('attachment', extension);
    final path = '$_resultsDirPath$source';
    File(path).writeAsBytesSync(bytes, flush: true);

    final step = steps[stepIndex];
    final attachments =
        (step['attachments'] as List?)?.cast<Map<String, dynamic>>() ??
            <Map<String, dynamic>>[];
    attachments.add({
      'name': snapshotName.isEmpty ? 'snapshot' : snapshotName,
      'source': source,
      'type': _mimeTypeForExtension(extension),
    });
    step['attachments'] = attachments;
  }

  Future<void> _finalize(_AllureTestRuntime runtime) async {
    if (_resultsDirPath == null || runtime.finished) return;
    runtime.finished = true;

    if (runtime.logBuffer.isNotEmpty) {
      final source = _nextArtifactName('attachment', 'txt');
      final path = '$_resultsDirPath$source';
      File(path).writeAsStringSync(runtime.logBuffer.toString(), flush: true);
      runtime.attachments.add({
        'name': 'raw-log',
        'source': source,
        'type': 'text/plain',
      });
    }

    final labels = <Map<String, String>>[
      {'name': 'framework', 'value': 'convenient_test'},
      {'name': 'language', 'value': 'dart'},
      {'name': 'host', 'value': Platform.localHostname},
    ];
    labels.addAll(_suiteLabelsForTest(runtime.testName));

    final result = <String, dynamic>{
      'uuid': runtime.uuid,
      'historyId': runtime.historyId,
      'name': runtime.testName,
      'fullName': runtime.fullName,
      'status': runtime.status ?? 'unknown',
      'stage': 'finished',
      'start': runtime.startMs,
      'stop': runtime.stopMs,
      'steps': runtime.steps,
      'attachments': runtime.attachments,
      'labels': labels,
      'parameters': [
        {
          'name': 'retryAttempt',
          'value': runtime.attemptIndex.toString(),
        },
      ],
    };
    if (runtime.statusDetails != null) {
      result['statusDetails'] = runtime.statusDetails;
    }

    final resultFileName = '${runtime.uuid}-result.json';
    final resultPath = '$_resultsDirPath$resultFileName';
    File(resultPath).writeAsStringSync(jsonEncode(result), flush: true);

    final active = _activeRuntimeByTestName[runtime.testName];
    if (identical(active, runtime)) {
      _activeRuntimeByTestName.remove(runtime.testName);
    }
  }

  List<Map<String, String>> _suiteLabelsForTest(String testName) {
    final suiteInfo = _suiteInfo;
    if (suiteInfo == null) return const [];
    final entryId = suiteInfo.getEntryIdFromName(testName);
    if (entryId == null) return const [];

    final groupNames = <String>[];
    var currentId = suiteInfo.entryMap[entryId]?.parentId ?? -1;
    while (suiteInfo.isIdValid(currentId)) {
      final entry = suiteInfo.entryMap[currentId];
      if (entry is GroupInfo && entry.name.trim().isNotEmpty) {
        groupNames.add(entry.name.trim());
      }
      currentId = entry?.parentId ?? -1;
    }
    final normalized = groupNames.reversed.toList();
    if (normalized.isEmpty) return const [];

    if (normalized.length == 1) {
      return [
        {'name': 'suite', 'value': normalized.first},
      ];
    }
    if (normalized.length == 2) {
      return [
        {'name': 'parentSuite', 'value': normalized.first},
        {'name': 'suite', 'value': normalized.last},
      ];
    }
    return [
      {'name': 'parentSuite', 'value': normalized.first},
      {'name': 'suite', 'value': normalized[1]},
      {'name': 'subSuite', 'value': normalized.sublist(2).join(' / ')},
    ];
  }

  _AllureTestRuntime _ensureActiveRuntime(String testName) {
    final active = _activeRuntimeByTestName[testName];
    if (active != null && !active.finished) {
      return active;
    }

    final nextAttempt = (_attemptCountByTestName[testName] ?? 0) + 1;
    _attemptCountByTestName[testName] = nextAttempt;
    final runtime = _AllureTestRuntime(
      uuid: _nextUuid(),
      testName: testName,
      fullName: testName,
      attemptIndex: nextAttempt,
    );
    _runtimeByUuid[runtime.uuid] = runtime;
    _activeRuntimeByTestName[testName] = runtime;
    _injectDeferredSetUpAllDataIfNeeded(runtime);
    return runtime;
  }

  bool _isServiceTestName(String? testName) {
    if (testName == null) return true;
    final normalized = testName.trim();
    return normalized.isEmpty ||
        normalized == '(setUpAll)' ||
        normalized == '(tearDownAll)';
  }

  bool _isSetUpAllServiceTestName(String? testName) =>
      testName?.trim() == '(setUpAll)';

  Map<String, dynamic> _buildStep(LogSubEntry sub, int subMs) {
    final step = <String, dynamic>{
      'name': _formatStepName(sub),
      'status': _statusForLogSubEntry(sub),
      'stage': 'finished',
      'start': subMs,
      'stop': subMs,
    };
    if (sub.error.isNotEmpty || sub.stackTrace.isNotEmpty) {
      step['statusDetails'] = {
        'message': sub.error,
        'trace': sub.stackTrace,
      };
    }
    return step;
  }

  String _formatRawLogLine(LogSubEntry sub, int subMs) {
    final stepName = _formatStepName(sub);
    return '[${DateTime.fromMillisecondsSinceEpoch(subMs).toUtc().toIso8601String()}] '
        '[${sub.type.name}] $stepName'
        '${sub.error.isEmpty ? '' : '\nERROR: ${sub.error}'}'
        '${sub.stackTrace.isEmpty ? '' : '\nSTACK: ${sub.stackTrace}'}';
  }

  void _drainPendingSnapshots(int logEntryId, String testName) {
    final pendingSnapshots = _pendingSnapshotsByLogEntryId.remove(logEntryId);
    if (pendingSnapshots == null) return;

    if (_isSetUpAllServiceTestName(testName)) {
      final deferredStepIndex =
          _deferredSetUpAllLastStepIndexByLogEntryId[logEntryId];
      if (deferredStepIndex == null) {
        _deferredSetUpAllAttachments.addAll(pendingSnapshots);
      } else {
        for (final pending in pendingSnapshots) {
          _attachSnapshotToStep(
            steps: _deferredSetUpAllSteps,
            stepIndex: deferredStepIndex,
            snapshotName: 'setUpAll:${pending.name}',
            bytes: pending.image,
          );
        }
      }
      return;
    }
    if (_isServiceTestName(testName)) return;

    final runtime = _runtimeByLogEntryId(logEntryId) ??
        _activeRuntimeByTestName[testName] ??
        _ensureActiveRuntime(testName);
    final stepIndex = _lastStepIndexByLogEntryId[logEntryId];
    for (final pending in pendingSnapshots) {
      if (stepIndex == null || runtime.finished) {
        _attachSnapshotToRuntime(runtime, pending.name, pending.image);
      } else {
        _attachSnapshotToStep(
          steps: runtime.steps,
          stepIndex: stepIndex,
          snapshotName: pending.name,
          bytes: pending.image,
        );
      }
    }
  }

  void _injectDeferredSetUpAllDataIfNeeded(_AllureTestRuntime runtime) {
    if (_deferredSetUpAllInjected) return;
    final hasDeferredData = _deferredSetUpAllSteps.isNotEmpty ||
        _deferredSetUpAllAttachments.isNotEmpty ||
        _deferredSetUpAllLogBuffer.isNotEmpty;
    if (!hasDeferredData) return;

    runtime.steps.insertAll(0, _deferredSetUpAllSteps);
    if (_deferredSetUpAllLogBuffer.isNotEmpty) {
      runtime.logBuffer.writeln('--- setUpAll ---');
      runtime.logBuffer.write(_deferredSetUpAllLogBuffer.toString());
      runtime.logBuffer.writeln('--- /setUpAll ---');
    }
    for (final attachment in _deferredSetUpAllAttachments) {
      _attachSnapshotToRuntime(
          runtime, 'setUpAll:${attachment.name}', attachment.image);
    }
    _deferredSetUpAllInjected = true;
  }

  String _formatStepName(LogSubEntry sub) {
    final title = sub.title.trim();
    final message = sub.message.trim();
    if (title.isEmpty) return message.isEmpty ? sub.type.name : message;
    if (message.isEmpty) return title;
    return '$title $message';
  }

  String _statusForLogSubEntry(LogSubEntry sub) {
    if (sub.type == LogSubEntryType.ASSERT_FAIL ||
        sub.error.isNotEmpty ||
        sub.stackTrace.isNotEmpty) {
      return 'failed';
    }
    return 'passed';
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

  int _usToMs(int value) => value ~/ 1000;

  String _detectImageExtension(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpg';
    }
    return 'bin';
  }

  String _mimeTypeForExtension(String extension) {
    switch (extension) {
      case 'png':
        return 'image/png';
      case 'jpg':
        return 'image/jpeg';
      default:
        return 'application/octet-stream';
    }
  }

  String _nextArtifactName(String prefix, String extension) {
    _artifactCounter++;
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    return '$prefix-${timestamp}_$_artifactCounter.$extension';
  }

  String _nextUuid() {
    final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final rand = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    _uuidCounter++;
    return '${timestamp}_${_uuidCounter}_$rand';
  }

  _AllureTestRuntime? _runtimeByLogEntryId(int logEntryId) {
    final runtimeUuid = _runtimeUuidByLogEntryId[logEntryId];
    if (runtimeUuid == null) return null;
    return _runtimeByUuid[runtimeUuid];
  }

  Future<void> _ensureActiveRunContext() async {
    final resultsDirPath =
        await GetIt.I.get<FsService>().getActiveSuperRunDataSubDirectory(
              category: 'AllureResults',
            );
    if (_resultsDirPath == resultsDirPath) {
      return;
    }

    _resultsDirPath = resultsDirPath;
    _resetState();
  }

  Future<void> _clearAllureResults() async {
    final resultsDirPath = _resultsDirPath;
    if (resultsDirPath == null) return;

    final resultsDir = Directory(resultsDirPath);
    if (resultsDir.existsSync()) {
      await resultsDir.delete(recursive: true);
    }
    await resultsDir.create(recursive: true);

    _resetState();
  }

  Uri _buildApiUri(
    String apiBaseUrl,
    String path, {
    required String projectId,
  }) {
    final baseUri = Uri.parse(apiBaseUrl);
    final normalizedPath =
        '${baseUri.path.endsWith('/') ? baseUri.path.substring(0, baseUri.path.length - 1) : baseUri.path}$path';
    return baseUri.replace(
      path: normalizedPath,
      queryParameters: {
        ...baseUri.queryParameters,
        'project_id': projectId,
      },
    );
  }

  Future<int> _sendResultsToAllureDocker({
    required String sourceDirPath,
    required String apiBaseUrl,
    required String projectId,
  }) async {
    final sourceDir = Directory(sourceDirPath);
    if (!sourceDir.existsSync()) return 0;

    final files = sourceDir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();
    if (files.isEmpty) return 0;

    final uri = _buildApiUri(apiBaseUrl, '/send-results', projectId: projectId);
    final boundary =
        '----ct-boundary-${DateTime.now().toUtc().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType('multipart', 'form-data',
          parameters: {'boundary': boundary});

      for (final file in files) {
        final fileName = file.uri.pathSegments.isEmpty
            ? file.path
            : file.uri.pathSegments.last;
        req.add(utf8.encode('--$boundary\r\n'));
        req.add(utf8.encode(
          'Content-Disposition: form-data; name="files[]"; filename="${_escapeHeaderValue(fileName)}"\r\n',
        ));
        req.add(utf8.encode('Content-Type: application/octet-stream\r\n\r\n'));
        await req.addStream(file.openRead());
        req.add(utf8.encode('\r\n'));
      }
      req.add(utf8.encode('--$boundary--\r\n'));

      final resp = await req.close().timeout(const Duration(minutes: 2));
      await resp.drain<void>();
      return resp.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  String _escapeHeaderValue(String value) =>
      value.replaceAll('\\', r'\\').replaceAll('"', r'\"');

  Future<int> _httpGetStatus(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 5));
      await resp.drain<void>();
      return resp.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  bool _autoPublishEnabled() {
    final value = environmentValue(_kAutoPublishEnabledEnvKey);
    if (value == null) return false;
    final normalized = value.trim().toLowerCase();
    return normalized == '1' ||
        normalized == 'true' ||
        normalized == 'yes' ||
        normalized == 'on';
  }

  Future<_AllureAutoPublishSettings> _resolveAutoPublishSettings() async {
    final configJson = await _readConvenientTestConfigJson();
    final configEnabled = _toNullableBool(configJson?[_kConfigEnableKey]);
    final envEnabled = _autoPublishEnabled();
    final enabled = configEnabled ?? envEnabled;

    final configApiBaseUrl =
        _toNullableString(configJson?[_kConfigApiBaseUrlKey]);
    final envApiBaseUrl = environmentValue(_kAutoPublishApiBaseUrlEnvKey);
    final apiBaseUrl = (() {
      final raw = configApiBaseUrl ?? envApiBaseUrl;
      if (raw == null || raw.trim().isEmpty) return _kDefaultDockerApiBaseUrl;
      return raw;
    })();

    final configProjectId = _toNullableString(configJson?[_kConfigProjectIdKey]);
    final envProjectId = environmentValue(_kAutoPublishProjectIdEnvKey);
    final projectId = configProjectId ?? envProjectId ?? _kDefaultProjectId;

    return _AllureAutoPublishSettings(
      enabled: enabled,
      apiBaseUrl: apiBaseUrl,
      projectId: projectId,
    );
  }

  Future<Map<String, dynamic>?> _readConvenientTestConfigJson() async {
    try {
      final homeDirectory = environmentValue('HOME');
      if (homeDirectory == null || homeDirectory.trim().isEmpty) return null;
      final configFilePath = '$homeDirectory/.config/convenient_test.json';
      final file = File(configFilePath);
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } catch (e, s) {
      Log.w(_kTag, 'read convenient_test.json failed e=$e s=$s');
      return null;
    }
  }

  bool? _toNullableBool(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
        return true;
      }
      if (normalized == 'false' || normalized == '0' || normalized == 'no') {
        return false;
      }
    }
    return null;
  }

  String? _toNullableString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }

  void _resetState() {
    _activeRuntimeByTestName.clear();
    _attemptCountByTestName.clear();
    _runtimeByUuid.clear();
    _testNameByLogEntryId.clear();
    _runtimeUuidByLogEntryId.clear();
    _lastStepIndexByLogEntryId.clear();
    _pendingSnapshotsByLogEntryId.clear();
    _deferredSetUpAllSteps.clear();
    _deferredSetUpAllLastStepIndexByLogEntryId.clear();
    _deferredSetUpAllAttachments.clear();
    _deferredSetUpAllLogBuffer = StringBuffer();
    _deferredSetUpAllInjected = false;
    _suiteInfo = null;
    _artifactCounter = 0;
    _uuidCounter = 0;
  }

  Future<bool> _openUrlDetached(String url) async {
    try {
      if (Platform.isMacOS) {
        await Process.start(
          'open',
          [url],
          runInShell: true,
          mode: ProcessStartMode.detached,
        );
        return true;
      }
      if (Platform.isWindows) {
        await Process.start(
          'cmd',
          ['/c', 'start', '', url],
          runInShell: true,
          mode: ProcessStartMode.detached,
        );
        return true;
      }
      await Process.start(
        'xdg-open',
        [url],
        runInShell: true,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (e, s) {
      Log.e(_kTag, 'open url failed e=$e s=$s url=$url');
      return false;
    }
  }

  final _random = Random();
  final _activeRuntimeByTestName = <String, _AllureTestRuntime>{};
  final _attemptCountByTestName = <String, int>{};
  final _runtimeByUuid = <String, _AllureTestRuntime>{};
  final _testNameByLogEntryId = <int, String>{};
  final _runtimeUuidByLogEntryId = <int, String>{};
  final _lastStepIndexByLogEntryId = <int, int>{};
  final _pendingSnapshotsByLogEntryId = <int, List<_PendingSnapshot>>{};
  final _deferredSetUpAllSteps = <Map<String, dynamic>>[];
  final _deferredSetUpAllLastStepIndexByLogEntryId = <int, int>{};
  final _deferredSetUpAllAttachments = <_PendingSnapshot>[];
  StringBuffer _deferredSetUpAllLogBuffer = StringBuffer();
  bool _deferredSetUpAllInjected = false;
  SuiteInfo? _suiteInfo;
  String? _resultsDirPath;
  String? _lastAutoPublishedSuperRunId;
  bool _autoPublishInProgress = false;
  int _artifactCounter = 0;
  int _uuidCounter = 0;
}

class _AllureAutoPublishSettings {
  final bool enabled;
  final String apiBaseUrl;
  final String projectId;

  const _AllureAutoPublishSettings({
    required this.enabled,
    required this.apiBaseUrl,
    required this.projectId,
  });
}

class _PendingSnapshot {
  final String name;
  final Uint8List image;

  const _PendingSnapshot({
    required this.name,
    required this.image,
  });
}

class _AllureTestRuntime {
  final String uuid;
  final String historyId;
  final String testName;
  final String fullName;
  final int attemptIndex;
  final List<Map<String, dynamic>> steps = [];
  final List<Map<String, dynamic>> attachments = [];
  final StringBuffer logBuffer = StringBuffer();
  String? status;
  Map<String, dynamic>? statusDetails;
  bool finished = false;

  int? _startMs;
  int? _stopMs;

  _AllureTestRuntime({
    required this.uuid,
    required this.testName,
    required this.fullName,
    required this.attemptIndex,
  }) : historyId = testName;

  int get startMs => _startMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
  int get stopMs => _stopMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;

  void touchAt(int ms) {
    _startMs = _startMs == null ? ms : min(_startMs!, ms);
    _stopMs = _stopMs == null ? ms : max(_stopMs!, ms);
  }
}
