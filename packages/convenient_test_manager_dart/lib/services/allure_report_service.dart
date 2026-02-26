import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/misc/runtime_platform.dart';
import 'package:convenient_test_manager_dart/services/fs_service.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:crypto/crypto.dart' as crypto;
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
  static const _kAutoPublishProjectPrefixEnvKey =
      'CONVENIENT_TEST_ALLURE_DOCKER_PROJECT_PREFIX';
  static const _kAutoPublishProjectEnvEnvKey =
      'CONVENIENT_TEST_ALLURE_DOCKER_PROJECT_ENV';
  static const _kAutoPublishProjectRepoEnvKey =
      'CONVENIENT_TEST_ALLURE_DOCKER_PROJECT_REPO';
  static const _kDefaultDockerApiBaseUrl =
      'http://localhost:5050/allure-docker-service';
  static const _kDefaultProjectId = 'default';
  static const _kConfigEnableKey = 'enableAllureDockerAutoPublish';
  static const _kConfigApiBaseUrlKey = 'allureDockerApiBaseUrl';
  static const _kConfigProjectIdKey = 'allureDockerProjectId';
  static const _kConfigProjectPrefixKey = 'allureDockerProjectPrefix';
  static const _kConfigProjectEnvKey = 'allureDockerProjectEnv';
  static const _kConfigProjectRepoKey = 'allureDockerProjectRepo';

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

    await autoPublishToDockerIfConfigured(force: true);

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

  Future<void> autoPublishToDockerIfConfigured({bool force = false}) async {
    if (!supportsIoPlatform) return;

    final settings = await _resolveAutoPublishSettings();
    if (!settings.enabled) return;

    final superRunId =
        GetIt.I.get<WorkerSuperRunStore>().currSuperRunController.superRunId;
    if (!force && _lastAutoPublishAttemptedSuperRunId == superRunId) return;
    if (_lastAutoPublishedSuperRunId == superRunId) return;
    if (_autoPublishInProgress) return;
    _lastAutoPublishAttemptedSuperRunId = superRunId;

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

      final latestReportUri = _buildApiUri(
        settings.apiBaseUrl,
        '/latest-report',
        projectId: settings.projectId,
      );
      _lastAutoPublishedSuperRunId = superRunId;
      Log.i(
        _kTag,
        'auto-publish success superRunId=$superRunId '
        'projectId=${settings.projectId} '
        'reportUrl=$latestReportUri '
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
        final suiteInfoDigest =
            crypto.sha1.convert(item.suiteInfoProto.writeToBuffer()).toString();
        final superRunId =
            GetIt.I.get<WorkerSuperRunStore>().currSuperRunController.superRunId;
        final shouldReset = _lastSuiteInfoDigestBySuperRunId[superRunId] !=
            suiteInfoDigest;
        _lastSuiteInfoDigestBySuperRunId[superRunId] = suiteInfoDigest;
        if (shouldReset) {
          await _clearAllureResults();
        } else {
          Log.i(
            _kTag,
            'suiteInfo deduplicated for superRunId=$superRunId, skip allure reset',
          );
        }
        _suiteInfo = SuiteInfo.fromProto(item.suiteInfoProto);
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
    _lastStepPointerByLogEntryId.remove(logEntryId);

    for (final sub in request.subEntries) {
      final subMs = _usToMs(sub.time.toInt());
      runtime.touchAt(subMs);

      final step = _buildStep(sub, subMs);
      final routing = _hookRoutingFromLogSubEntry(
        runtime: runtime,
        sub: sub,
      );
      _lastStepPointerByLogEntryId[logEntryId] = _appendStepByRouting(
        runtime: runtime,
        routing: routing,
        step: step,
      );
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
    final stepPointer = _lastStepPointerByLogEntryId[logEntryId];
    if (stepPointer == null || runtime.finished) {
      _attachSnapshotToRuntime(
          runtime, request.name, request.image as Uint8List);
    } else {
      final steps = _stepsForPointer(runtime, stepPointer);
      if (steps == null) {
        _attachSnapshotToRuntime(
            runtime, request.name, request.image as Uint8List);
        return;
      }
      _attachSnapshotToStep(
        steps: steps,
        stepIndex: stepPointer.index,
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

  void _attachSnapshotToFixture({
    required _AllureFixtureRuntime fixture,
    required String snapshotName,
    required Uint8List bytes,
  }) {
    if (_resultsDirPath == null) return;
    final extension = _detectImageExtension(bytes);
    final source = _nextArtifactName('attachment', extension);
    final path = '$_resultsDirPath$source';
    File(path).writeAsBytesSync(bytes, flush: true);

    fixture.attachments.add({
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

    final suiteGroupNames = _suiteGroupNamesForTest(runtime.testName);
    _decorateSetupFixtureByGroups(
      runtime: runtime,
      suiteGroupNames: suiteGroupNames,
    );
    final displayName = _displayNameForTest(runtime.testName);

    final labels = <Map<String, String>>[
      {'name': 'framework', 'value': 'convenient_test'},
      {'name': 'language', 'value': 'dart'},
      {'name': 'host', 'value': Platform.localHostname},
    ];
    labels.addAll(_suiteLabelsForTest(runtime.testName));

    final result = <String, dynamic>{
      'uuid': runtime.uuid,
      'historyId': runtime.historyId,
      'name': displayName,
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
    await _writeContainer(runtime);

    final active = _activeRuntimeByTestName[runtime.testName];
    if (identical(active, runtime)) {
      _activeRuntimeByTestName.remove(runtime.testName);
    }
  }

  List<Map<String, String>> _suiteLabelsForTest(String testName) {
    final normalized = _suiteGroupNamesForTest(testName);
    if (normalized.isEmpty) return const [];

    final labels = <Map<String, String>>[];
    final seen = <String>{};
    void addLabel(String name, String value) {
      final clean = value.trim();
      if (clean.isEmpty) return;
      final key = '$name::$clean';
      if (!seen.add(key)) return;
      labels.add({'name': name, 'value': clean});
    }

    // Suites tab mapping (Allure has 3 canonical levels).
    if (normalized.length == 1) {
      addLabel('suite', normalized.first);
    } else if (normalized.length == 2) {
      addLabel('parentSuite', normalized.first);
      addLabel('suite', normalized.last);
    } else {
      addLabel('parentSuite', normalized.first);
      addLabel('suite', normalized[1]);
      addLabel('subSuite', normalized.sublist(2).join(' / '));
    }

    // Behavior tab mapping.
    addLabel('epic', normalized.first);
    if (normalized.length >= 2) {
      addLabel('feature', normalized[1]);
    }
    if (normalized.length >= 3) {
      addLabel('story', normalized.sublist(2).join(' / '));
    }

    // Keep full hierarchy searchable and visible in custom labels/tags.
    final groupPath = normalized.join(' / ');
    addLabel('tag', 'groupPath:$groupPath');
    for (var i = 0; i < normalized.length; i++) {
      addLabel('tag', 'groupLevel${i + 1}:${normalized[i]}');
    }

    return labels;
  }

  List<String> _suiteGroupNamesForTest(String testName) {
    final suiteInfo = _suiteInfo;
    if (suiteInfo == null) return const [];
    final entryId = _resolveSuiteEntryIdForTestName(suiteInfo, testName);
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
    return groupNames.reversed.toList();
  }

  String _displayNameForTest(String testName) {
    final suiteInfo = _suiteInfo;
    if (suiteInfo == null) return testName;
    final entryId = _resolveSuiteEntryIdForTestName(suiteInfo, testName);
    if (entryId == null) return testName;
    final entry = suiteInfo.entryMap[entryId];
    if (entry is TestInfo && entry.name.trim().isNotEmpty) {
      return entry.name.trim();
    }
    return testName;
  }

  void _decorateSetupFixtureByGroups({
    required _AllureTestRuntime runtime,
    required List<String> suiteGroupNames,
  }) {
    final setupFixture = runtime.beforeFixtures['SETUP'];
    if (setupFixture == null) return;
    if (setupFixture.steps.length <= 1) return;

    final blocks = <List<Map<String, dynamic>>>[];
    var currentBlock = <Map<String, dynamic>>[];
    for (final step in setupFixture.steps) {
      final stepName = (step['name'] as String?)?.trim().toUpperCase() ?? '';
      if (stepName == 'SETUP' && currentBlock.isNotEmpty) {
        blocks.add(currentBlock);
        currentBlock = <Map<String, dynamic>>[];
      }
      currentBlock.add(step);
    }
    if (currentBlock.isNotEmpty) {
      blocks.add(currentBlock);
    }
    if (blocks.length <= 1) return;

    final wrappers = <Map<String, dynamic>>[];
    final offset = max(0, suiteGroupNames.length - blocks.length);
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final start = (block.first['start'] as int?) ?? runtime.startMs;
      final stop = (block.last['stop'] as int?) ?? runtime.stopMs;
      final groupName = (i + offset < suiteGroupNames.length)
          ? suiteGroupNames[i + offset]
          : 'group-${i + 1}';
      final hasFailed = block.any((e) =>
          (e['status'] as String?) == 'failed' ||
          (e['status'] as String?) == 'broken');
      wrappers.add({
        'name': 'SETUP [$groupName]',
        'status': hasFailed ? 'failed' : 'passed',
        'stage': 'finished',
        'start': start,
        'stop': stop,
        'steps': block,
      });
    }
    setupFixture.steps
      ..clear()
      ..addAll(wrappers);
  }

  int? _resolveSuiteEntryIdForTestName(SuiteInfo suiteInfo, String testName) {
    final exact = suiteInfo.getEntryIdFromName(testName);
    if (exact != null) return exact;

    final normalizedTestName = _normalizeSuiteName(testName);
    if (normalizedTestName.isEmpty) return null;

    int? bestId;
    var bestScore = -1;
    for (final entry in suiteInfo.entryMap.entries) {
      if (entry.value is! TestInfo) continue;
      final candidateName = entry.value.name;
      final normalizedCandidate = _normalizeSuiteName(candidateName);
      if (normalizedCandidate.isEmpty) continue;

      var score = -1;
      if (normalizedCandidate == normalizedTestName) {
        score = 100000 + normalizedCandidate.length;
      } else if (normalizedTestName.endsWith(normalizedCandidate) &&
          (normalizedTestName.length == normalizedCandidate.length ||
              normalizedTestName[normalizedTestName.length -
                      normalizedCandidate.length -
                      1] ==
                  ' ')) {
        // Common case: runtime test name contains group prefixes while suite
        // info contains only the leaf test title.
        score = 10000 + normalizedCandidate.length;
      } else if (normalizedTestName.contains(normalizedCandidate)) {
        score = normalizedCandidate.length;
      }

      if (score > bestScore) {
        bestScore = score;
        bestId = entry.key;
      }
    }

    return bestScore >= 0 ? bestId : null;
  }

  String _normalizeSuiteName(String input) {
    final lower = input.trim().toLowerCase();
    if (lower.isEmpty) return '';
    return lower.replaceAll(RegExp(r'\s+'), ' ');
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
    final stepPointer = _lastStepPointerByLogEntryId[logEntryId];
    for (final pending in pendingSnapshots) {
      if (stepPointer == null || runtime.finished) {
        _attachSnapshotToRuntime(runtime, pending.name, pending.image);
      } else {
        final steps = _stepsForPointer(runtime, stepPointer);
        if (steps == null) {
          _attachSnapshotToRuntime(runtime, pending.name, pending.image);
          continue;
        }
        _attachSnapshotToStep(
          steps: steps,
          stepIndex: stepPointer.index,
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

    final beforeFixture = runtime.ensureBeforeFixture('SETUP_ALL');
    beforeFixture.steps.addAll(_deferredSetUpAllSteps);
    if (_deferredSetUpAllSteps.isNotEmpty) {
      final start =
          (_deferredSetUpAllSteps.first['start'] as int?) ?? runtime.startMs;
      final stop =
          (_deferredSetUpAllSteps.last['stop'] as int?) ?? runtime.startMs;
      beforeFixture.touchRange(start: start, stop: stop);
    }
    if (_deferredSetUpAllLogBuffer.isNotEmpty) {
      runtime.logBuffer.writeln('--- SETUP_ALL ---');
      runtime.logBuffer.write(_deferredSetUpAllLogBuffer.toString());
      runtime.logBuffer.writeln('--- /SETUP_ALL ---');
    }
    for (final attachment in _deferredSetUpAllAttachments) {
      _attachSnapshotToFixture(
        fixture: beforeFixture,
        snapshotName: 'SETUP_ALL:${attachment.name}',
        bytes: attachment.image,
      );
    }
    _deferredSetUpAllInjected = true;
  }

  _AllureHookRouting _hookRoutingFromLogSubEntry({
    required _AllureTestRuntime runtime,
    required LogSubEntry sub,
  }) {
    final haystack = '${sub.title} ${sub.message}'.toUpperCase();
    if (haystack.contains('TEARDOWN_ALL')) {
      return const _AllureHookRouting.after('TEARDOWN_ALL');
    }
    if (haystack.contains('TEARDOWN')) {
      return const _AllureHookRouting.after('TEARDOWN');
    }
    if (haystack.contains('SETUP_ALL')) {
      return const _AllureHookRouting.before('SETUP_ALL');
    }
    if (haystack.contains('SETUP')) {
      return const _AllureHookRouting.before('SETUP');
    }
    if (_isBodyStartMarker(sub)) {
      runtime.hasSeenBodyStart = true;
      return const _AllureHookRouting.body();
    }
    if (!runtime.hasSeenBodyStart) {
      // Before the explicit START marker, treat steps as per-test setup.
      return const _AllureHookRouting.before('SETUP');
    }
    return const _AllureHookRouting.body();
  }

  bool _isBodyStartMarker(LogSubEntry sub) {
    final name = _formatStepName(sub).trim().toUpperCase();
    return name == 'START' || name.startsWith('START ');
  }

  _AllureStepPointer _appendStepByRouting({
    required _AllureTestRuntime runtime,
    required _AllureHookRouting routing,
    required Map<String, dynamic> step,
  }) {
    switch (routing.section) {
      case _AllureHookSection.before:
        final fixtureName = routing.fixtureName ?? 'SETUP';
        final fixture = runtime.ensureBeforeFixture(fixtureName);
        final index = fixture.steps.length;
        fixture.steps.add(step);
        fixture.absorbStep(step);
        return _AllureStepPointer.before(
          fixtureName: fixtureName,
          index: index,
        );
      case _AllureHookSection.after:
        final fixtureName = routing.fixtureName ?? 'TEARDOWN';
        final fixture = runtime.ensureAfterFixture(fixtureName);
        final index = fixture.steps.length;
        fixture.steps.add(step);
        fixture.absorbStep(step);
        return _AllureStepPointer.after(
          fixtureName: fixtureName,
          index: index,
        );
      case _AllureHookSection.body:
        final index = runtime.steps.length;
        runtime.steps.add(step);
        return _AllureStepPointer.body(index: index);
    }
  }

  List<Map<String, dynamic>>? _stepsForPointer(
    _AllureTestRuntime runtime,
    _AllureStepPointer pointer,
  ) {
    switch (pointer.section) {
      case _AllureHookSection.body:
        return runtime.steps;
      case _AllureHookSection.before:
        final fixtureName = pointer.fixtureName;
        if (fixtureName == null) return null;
        return runtime.beforeFixtures[fixtureName]?.steps;
      case _AllureHookSection.after:
        final fixtureName = pointer.fixtureName;
        if (fixtureName == null) return null;
        return runtime.afterFixtures[fixtureName]?.steps;
    }
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

  Future<void> _writeContainer(_AllureTestRuntime runtime) async {
    if (_resultsDirPath == null) return;
    final befores =
        runtime.beforeFixtures.values.map((e) => e.toJson()).toList();
    final afters = runtime.afterFixtures.values.map((e) => e.toJson()).toList();
    if (befores.isEmpty && afters.isEmpty) return;

    final containerUuid = _nextUuid();
    final container = <String, dynamic>{
      'uuid': containerUuid,
      'name': runtime.fullName,
      'children': [runtime.uuid],
      'befores': befores,
      'afters': afters,
      'start': runtime.startMs,
      'stop': runtime.stopMs,
    };
    final containerPath = '$_resultsDirPath$containerUuid-container.json';
    File(containerPath).writeAsStringSync(jsonEncode(container), flush: true);
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

    final multipartStatus = await _sendResultsMultipart(
      files: files,
      apiBaseUrl: apiBaseUrl,
      projectId: projectId,
      sourceDirPath: sourceDirPath,
    );
    if (multipartStatus >= 200 && multipartStatus < 300) {
      Log.i(_kTag, 'send-results success via multipart files[]');
      return multipartStatus;
    }

    Log.w(
      _kTag,
      'send-results multipart failed status=$multipartStatus, retrying as json base64',
    );
    final jsonStatus = await _sendResultsJsonBase64(
      files: files,
      apiBaseUrl: apiBaseUrl,
      projectId: projectId,
      sourceDirPath: sourceDirPath,
    );
    if (jsonStatus >= 200 && jsonStatus < 300) {
      Log.i(_kTag, 'send-results success via json results[]');
    }
    return jsonStatus;
  }

  String _escapeHeaderValue(String value) =>
      value.replaceAll('\\', r'\\').replaceAll('"', r'\"');

  Future<int> _sendResultsMultipart({
    required List<File> files,
    required String apiBaseUrl,
    required String projectId,
    required String sourceDirPath,
  }) async {
    final uri = _buildApiUri(apiBaseUrl, '/send-results', projectId: projectId)
        .replace(queryParameters: {
      ..._buildApiUri(apiBaseUrl, '/send-results', projectId: projectId)
          .queryParameters,
      'force_project_creation': 'true',
    });
    final boundary =
        '----ct-boundary-${DateTime.now().toUtc().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
    final rootPath = sourceDirPath.endsWith(Platform.pathSeparator)
        ? sourceDirPath
        : '$sourceDirPath${Platform.pathSeparator}';

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType('multipart', 'form-data',
          parameters: {'boundary': boundary});

      for (final file in files) {
        final fileName = file.path.startsWith(rootPath)
            ? file.path.substring(rootPath.length)
            : (file.uri.pathSegments.isEmpty
                ? file.path
                : file.uri.pathSegments.last);
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
    } catch (e, s) {
      Log.w(_kTag, 'send-results multipart exception e=$e s=$s');
      return 0;
    } finally {
      client.close(force: true);
    }
  }

  Future<int> _sendResultsJsonBase64({
    required List<File> files,
    required String apiBaseUrl,
    required String projectId,
    required String sourceDirPath,
  }) async {
    final uri = _buildApiUri(apiBaseUrl, '/send-results', projectId: projectId)
        .replace(queryParameters: {
      ..._buildApiUri(apiBaseUrl, '/send-results', projectId: projectId)
          .queryParameters,
      'force_project_creation': 'true',
    });
    final rootPath = sourceDirPath.endsWith(Platform.pathSeparator)
        ? sourceDirPath
        : '$sourceDirPath${Platform.pathSeparator}';

    final results = <Map<String, String>>[];
    for (final file in files) {
      final relativeName = file.path.startsWith(rootPath)
          ? file.path.substring(rootPath.length)
          : (file.uri.pathSegments.isEmpty
              ? file.path
              : file.uri.pathSegments.last);
      final bytes = await file.readAsBytes();
      results.add({
        'file_name': relativeName,
        'content_base64': base64Encode(bytes),
      });
    }

    final payload = jsonEncode({
      'results': results,
    });

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType('application', 'json');
      req.add(utf8.encode(payload));
      final resp = await req.close().timeout(const Duration(minutes: 2));
      await resp.drain<void>();
      return resp.statusCode;
    } catch (e, s) {
      Log.w(_kTag, 'send-results json exception e=$e s=$s');
      return 0;
    } finally {
      client.close(force: true);
    }
  }

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

    final configProjectId =
        _toNullableString(configJson?[_kConfigProjectIdKey]);
    final envProjectId = environmentValue(_kAutoPublishProjectIdEnvKey);
    final configProjectPrefix =
        _toNullableString(configJson?[_kConfigProjectPrefixKey]);
    final envProjectPrefix = environmentValue(_kAutoPublishProjectPrefixEnvKey);
    final configProjectEnv =
        _toNullableString(configJson?[_kConfigProjectEnvKey]);
    final configProjectRepo =
        _toNullableString(configJson?[_kConfigProjectRepoKey]);
    final envProjectEnv = _firstNonEmptyEnvironmentValue(const [
      _kAutoPublishProjectEnvEnvKey,
      'CONVENIENT_TEST_ENV',
      'APP_ENV',
      'ENVIRONMENT',
      'FLAVOR',
    ]);
    final envProjectRepo = _firstNonEmptyEnvironmentValue(const [
      _kAutoPublishProjectRepoEnvKey,
      'GITHUB_REPOSITORY',
    ]);

    final projectId = await _resolveProjectId(
      explicitProjectId: configProjectId ?? envProjectId,
      projectPrefix: configProjectPrefix ?? envProjectPrefix,
      explicitEnv: configProjectEnv ?? envProjectEnv,
      explicitRepo: configProjectRepo ?? envProjectRepo,
    );

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

  Future<String> _resolveProjectId({
    required String? explicitProjectId,
    required String? projectPrefix,
    required String? explicitEnv,
    required String? explicitRepo,
  }) async {
    if (explicitProjectId != null && explicitProjectId.trim().isNotEmpty) {
      return _normalizeProjectId(explicitProjectId);
    }

    final repoNameRaw = await _resolveRepoName(explicitRepo: explicitRepo);
    final envNameRaw = _resolveEnvironmentName(explicitEnv: explicitEnv);
    final repoName = _normalizeProjectId(repoNameRaw);
    final envName = _normalizeProjectId(envNameRaw);
    final prefix = projectPrefix?.trim();
    final raw = [
      if (prefix != null && prefix.isNotEmpty) prefix,
      repoName.isEmpty ? 'project' : repoName,
      Platform.operatingSystem,
      envName.isEmpty ? 'unknown' : envName,
    ].join('-');
    final normalized = _normalizeProjectId(raw);
    if (normalized.isEmpty) return _kDefaultProjectId;
    return normalized;
  }

  Future<String> _resolveRepoName({required String? explicitRepo}) async {
    final fromExplicit = _normalizeRepoNameCandidate(explicitRepo);
    if (fromExplicit != null) return fromExplicit;

    try {
      final result = await Process.run(
        'git',
        ['rev-parse', '--show-toplevel'],
        runInShell: true,
      ).timeout(const Duration(seconds: 2));
      if (result.exitCode == 0) {
        final root = (result.stdout as String).trim();
        final rootSegment = _lastPathSegment(root);
        final normalized = _normalizeRepoNameCandidate(rootSegment);
        if (normalized != null) return normalized;
      }
    } catch (_) {
      // Fall back to current directory name.
    }

    final cwdName = _lastPathSegment(Directory.current.path);
    return _normalizeRepoNameCandidate(cwdName) ?? 'project';
  }

  String _resolveEnvironmentName({required String? explicitEnv}) {
    final normalized = _normalizeRepoNameCandidate(explicitEnv);
    if (normalized != null) return normalized;
    return 'unknown';
  }

  String? _normalizeRepoNameCandidate(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    // Support formats like "org/repo" from CI variables.
    final last = _lastPathSegment(trimmed.replaceAll(':', '/'));
    final clean = last.trim();
    if (clean.isEmpty) return null;
    return clean;
  }

  String? _firstNonEmptyEnvironmentValue(List<String> keys) {
    for (final key in keys) {
      final value = environmentValue(key);
      if (value != null && value.trim().isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  String _lastPathSegment(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/').where((e) => e.trim().isNotEmpty);
    if (parts.isEmpty) return '';
    return parts.last;
  }

  String _normalizeProjectId(String raw) {
    final lower = raw.toLowerCase();
    final buffer = StringBuffer();
    var prevDash = false;
    for (final code in lower.codeUnits) {
      final isAlphaNum =
          (code >= 97 && code <= 122) || (code >= 48 && code <= 57);
      final isAllowedPunct = code == 45;
      if (isAlphaNum || isAllowedPunct) {
        buffer.writeCharCode(code);
        prevDash = false;
      } else {
        if (!prevDash) {
          buffer.write('-');
          prevDash = true;
        }
      }
    }
    var normalized = buffer.toString();
    normalized = normalized.replaceAll(RegExp('^-+'), '');
    normalized = normalized.replaceAll(RegExp('-+\$'), '');
    normalized = normalized.replaceAll(RegExp('-{2,}'), '-');
    if (normalized.length > 120) {
      normalized = normalized.substring(0, 120);
      normalized = normalized.replaceAll(RegExp('-+\$'), '');
    }
    return normalized;
  }

  void _resetState() {
    _activeRuntimeByTestName.clear();
    _attemptCountByTestName.clear();
    _runtimeByUuid.clear();
    _testNameByLogEntryId.clear();
    _runtimeUuidByLogEntryId.clear();
    _lastStepPointerByLogEntryId.clear();
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
  final _lastStepPointerByLogEntryId = <int, _AllureStepPointer>{};
  final _pendingSnapshotsByLogEntryId = <int, List<_PendingSnapshot>>{};
  final _deferredSetUpAllSteps = <Map<String, dynamic>>[];
  final _deferredSetUpAllLastStepIndexByLogEntryId = <int, int>{};
  final _deferredSetUpAllAttachments = <_PendingSnapshot>[];
  StringBuffer _deferredSetUpAllLogBuffer = StringBuffer();
  bool _deferredSetUpAllInjected = false;
  SuiteInfo? _suiteInfo;
  String? _resultsDirPath;
  String? _lastAutoPublishAttemptedSuperRunId;
  String? _lastAutoPublishedSuperRunId;
  bool _autoPublishInProgress = false;
  int _artifactCounter = 0;
  int _uuidCounter = 0;
  final _lastSuiteInfoDigestBySuperRunId = <String, String>{};
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
  final Map<String, _AllureFixtureRuntime> beforeFixtures = {};
  final Map<String, _AllureFixtureRuntime> afterFixtures = {};
  final StringBuffer logBuffer = StringBuffer();
  String? status;
  Map<String, dynamic>? statusDetails;
  bool finished = false;
  bool hasSeenBodyStart = false;

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

  _AllureFixtureRuntime ensureBeforeFixture(String name) =>
      beforeFixtures.putIfAbsent(name, () => _AllureFixtureRuntime(name: name));

  _AllureFixtureRuntime ensureAfterFixture(String name) =>
      afterFixtures.putIfAbsent(name, () => _AllureFixtureRuntime(name: name));
}

class _AllureFixtureRuntime {
  final String name;
  final List<Map<String, dynamic>> steps = [];
  final List<Map<String, dynamic>> attachments = [];
  String? _status;
  int? _startMs;
  int? _stopMs;

  _AllureFixtureRuntime({required this.name});

  void absorbStep(Map<String, dynamic> step) {
    final stepStatus = (step['status'] as String?) ?? 'passed';
    if (stepStatus == 'failed' || stepStatus == 'broken') {
      _status = 'failed';
    } else {
      _status ??= 'passed';
    }

    final start = step['start'] as int?;
    final stop = step['stop'] as int?;
    if (start != null || stop != null) {
      touchRange(
        start: start ?? stop ?? _nowMs(),
        stop: stop ?? start ?? _nowMs(),
      );
    }
  }

  void touchRange({
    required int start,
    required int stop,
  }) {
    _startMs = _startMs == null ? start : min(_startMs!, start);
    _stopMs = _stopMs == null ? stop : max(_stopMs!, stop);
  }

  int _nowMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'name': name,
        'status': _status ?? 'passed',
        'stage': 'finished',
        'start': _startMs ?? _nowMs(),
        'stop': _stopMs ?? _nowMs(),
        'steps': _buildDisplaySteps(),
        'attachments': attachments,
      };

  List<Map<String, dynamic>> _buildDisplaySteps() {
    return steps;
  }
}

enum _AllureHookSection { body, before, after }

class _AllureHookRouting {
  final _AllureHookSection section;
  final String? fixtureName;

  const _AllureHookRouting.body()
      : section = _AllureHookSection.body,
        fixtureName = null;
  const _AllureHookRouting.before(this.fixtureName)
      : section = _AllureHookSection.before;
  const _AllureHookRouting.after(this.fixtureName)
      : section = _AllureHookSection.after;
}

class _AllureStepPointer {
  final _AllureHookSection section;
  final int index;
  final String? fixtureName;

  const _AllureStepPointer.body({
    required this.index,
  })  : section = _AllureHookSection.body,
        fixtureName = null;

  const _AllureStepPointer.before({
    required this.fixtureName,
    required this.index,
  }) : section = _AllureHookSection.before;

  const _AllureStepPointer.after({
    required this.fixtureName,
    required this.index,
  }) : section = _AllureHookSection.after;
}
