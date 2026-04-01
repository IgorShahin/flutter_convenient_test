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
  static const _kGenerateOpenPublishTimeout = Duration(seconds: 20);
  static const _kVideoChunkSnapshotPrefix = '__ct_video_chunk__';
  static const _kTextAttachmentTitlePrefix = '__CT_TEXT_ATTACHMENT__:';
  static const _kAllureTagsPrefix = '__CT_ALLURE_TAGS__:';

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

  Future<bool> generateAndOpenSite() async {
    if (!supportsIoPlatform) {
      Log.w(_kTag, 'generateAndOpenSite skipped on non-io runtime');
      return false;
    }
    return generateLocalSiteIfPossible(openWhenDone: true);
  }

  Future<bool> generateLocalSiteIfPossible({bool openWhenDone = false}) async {
    if (!supportsIoPlatform) {
      Log.w(_kTag, 'generateLocalSiteIfPossible skipped on non-io runtime');
      return false;
    }

    await _ensureActiveRunContext();
    final resultsDirPath = _resultsDirPath;
    if (resultsDirPath == null) {
      Log.w(_kTag, 'skip local allure generation: results dir path is null');
      return false;
    }

    final hasResults = Directory(resultsDirPath)
        .listSync()
        .whereType<File>()
        .any((f) => f.path.endsWith('-result.json'));
    if (!hasResults) {
      Log.i(_kTag, 'skip local allure generation: no result files');
      return false;
    }

    final reportDirPath =
        await GetIt.I.get<FsService>().getActiveSuperRunDataSubDirectory(
              category: 'AllureReport',
            );

    try {
      final result = await Process.run(
        'allure',
        ['generate', resultsDirPath, '--clean', '-o', reportDirPath],
        runInShell: true,
      ).timeout(const Duration(seconds: 60));
      if (result.exitCode != 0) {
        Log.w(
          _kTag,
          'local allure generation failed exitCode=${result.exitCode} '
          'stdout=${(result.stdout as Object?)?.toString().trim()} '
          'stderr=${(result.stderr as Object?)?.toString().trim()}',
        );
        return false;
      }
      Log.i(_kTag, 'local allure report generated at path=$reportDirPath');
    } catch (e, s) {
      Log.w(
        _kTag,
        'local allure generation skipped (is `allure` installed?) e=$e s=$s',
      );
      return false;
    }

    if (!openWhenDone) return true;
    final reportIndexPath = '$reportDirPath/index.html';
    final started =
        await _openUrlDetached(Uri.file(reportIndexPath).toString());
    if (!started) {
      Log.w(_kTag, 'local allure report open failed path=$reportIndexPath');
      return false;
    }
    Log.i(_kTag, 'local allure report opened path=$reportIndexPath');
    return true;
  }

  Future<bool> openLatestReportSite() async {
    if (!supportsIoPlatform) {
      Log.w(_kTag, 'openLatestReportSite skipped on non-io runtime');
      return false;
    }
    await _ensureActiveRunContext();
    final reportDirPath =
        await GetIt.I.get<FsService>().getActiveSuperRunDataSubDirectory(
              category: 'AllureReport',
            );
    final reportIndexPath = '$reportDirPath/index.html';
    final reportIndexFile = File(reportIndexPath);
    if (!reportIndexFile.existsSync()) {
      return generateLocalSiteIfPossible(openWhenDone: true);
    }

    final started =
        await _openUrlDetached(Uri.file(reportIndexPath).toString());
    if (!started) return false;
    Log.i(_kTag, 'local allure report opened path=$reportIndexPath');
    return true;
  }

  Future<bool> clearRemoteHistory({bool clearResults = false}) async {
    if (!supportsIoPlatform) {
      Log.w(_kTag, 'clearRemoteHistory skipped on non-io runtime');
      return false;
    }
    await _clearLocalAllureArtifacts(clearResults: clearResults);
    Log.i(_kTag, 'clearRemoteHistory mapped to local allure cleanup');
    return true;
  }

  Future<void> autoPublishToDockerIfConfigured({bool force = false}) async {
    if (!supportsIoPlatform) return;

    final superRunId =
        GetIt.I.get<WorkerSuperRunStore>().currSuperRunController.superRunId;
    if (!force && _lastAutoPublishAttemptedSuperRunId == superRunId) return;
    if (_lastAutoPublishedSuperRunId == superRunId) return;
    if (_autoPublishInProgress) return;
    _lastAutoPublishAttemptedSuperRunId = superRunId;

    _autoPublishInProgress = true;
    try {
      final generated = await generateLocalSiteIfPossible(openWhenDone: false)
          .timeout(_kGenerateOpenPublishTimeout);
      if (!generated) {
        Log.i(
          _kTag,
          'local allure generation skipped or failed superRunId=$superRunId',
        );
        return;
      }
      _lastAutoPublishedSuperRunId = superRunId;
      Log.i(
        _kTag,
        'local allure generation completed superRunId=$superRunId',
      );
    } on TimeoutException catch (e, s) {
      Log.w(_kTag, 'local allure generation timeout e=$e s=$s');
    } catch (e, s) {
      Log.w(_kTag, 'local allure generation failed e=$e s=$s');
    } finally {
      _autoPublishInProgress = false;
    }
  }

  Future<void> _handleItem(ReportItem item) async {
    switch (item.whichSubType()) {
      case ReportItem_SubType.suiteInfoProto:
        final suiteInfoDigest =
            crypto.sha1.convert(item.suiteInfoProto.writeToBuffer()).toString();
        final superRunId = GetIt.I
            .get<WorkerSuperRunStore>()
            .currSuperRunController
            .superRunId;
        final shouldReset =
            _lastSuiteInfoDigestBySuperRunId[superRunId] != suiteInfoDigest;
        _lastSuiteInfoDigestBySuperRunId[superRunId] = suiteInfoDigest;
        if (shouldReset) {
          _resetRuntimeState();
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
        return;
      case ReportItem_SubType.tearDownAll:
        await _handleTearDownAll();
        return;
      case ReportItem_SubType.notSet:
        return;
    }
  }

  Future<void> _handleTearDownAll() async {
    await _backfillVideosForFinishedTests();
  }

  void _handleLogEntry(LogEntry request) {
    final logEntryId = request.id.toInt();
    _testNameByLogEntryId[logEntryId] = request.testName;
    if (_isSetUpAllServiceTestName(request.testName)) {
      if (_isPureHttpLogEntry(request)) {
        for (final sub in request.subEntries) {
          final subMs = _usToMs(sub.time.toInt());
          _deferredSetUpAllLogBuffer.writeln(_formatRawLogLine(sub, subMs));
        }
        _drainPendingSnapshots(logEntryId, request.testName);
        return;
      }
      _runtimeUuidByLogEntryId.remove(logEntryId);
      _deferredSetUpAllLastStepIndexByLogEntryId.remove(logEntryId);
      for (final sub in request.subEntries) {
        final subMs = _usToMs(sub.time.toInt());
        if (_isTextAttachmentMarker(sub)) {
          _handleDeferredTextAttachment(logEntryId: logEntryId, sub: sub);
          continue;
        }
        final prevIndex =
            _deferredSetUpAllLastStepIndexByLogEntryId[logEntryId];
        if (prevIndex != null &&
            prevIndex >= 0 &&
            prevIndex < _deferredSetUpAllSteps.length) {
          final prevStep = _deferredSetUpAllSteps[prevIndex];
          final prevStart = (prevStep['start'] as int?) ?? subMs;
          prevStep['stop'] = max(prevStart, subMs);
        }
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

    final runtime = _runtimeForIncomingEvent(request.testName);
    final wasFinished = runtime.finished;
    _runtimeUuidByLogEntryId[logEntryId] = runtime.uuid;
    _lastStepPointerByLogEntryId.remove(logEntryId);

    if (_isPureHttpLogEntry(request)) {
      for (final sub in request.subEntries) {
        final subMs = _usToMs(sub.time.toInt());
        runtime.touchAt(subMs);
        runtime.logBuffer.writeln(_formatRawLogLine(sub, subMs));
      }
      _attachHttpLogEntryToPendingCheck(runtime: runtime, request: request);
      _drainPendingSnapshots(logEntryId, request.testName);
      return;
    }

    var hasHttpCheckMarker = false;

    for (final sub in request.subEntries) {
      final subMs = _usToMs(sub.time.toInt());
      runtime.touchAt(subMs);

      final prevPointer = _lastOpenStepPointerByRuntimeUuid[runtime.uuid];
      if (prevPointer != null) {
        _closeStepPointer(
            runtime: runtime, pointer: prevPointer, stopMs: subMs);
      }

      if (_isTextAttachmentMarker(sub)) {
        _attachTextAttachmentToCurrentContext(
          runtime: runtime,
          logEntryId: logEntryId,
          sub: sub,
        );
        continue;
      }

      if (_shouldSkipErrorLikeSubEntry(runtime, sub)) {
        runtime.logBuffer.writeln(_formatRawLogLine(sub, subMs));
        continue;
      }

      final errorSignature = _isExceptionLikeLogSubEntry(sub)
          ? _errorSignature(
              message: _exceptionLikeMessage(sub),
              trace: _exceptionLikeTrace(sub),
            )
          : null;
      if (errorSignature != null &&
          runtime.errorSignatures.contains(errorSignature)) {
        runtime.logBuffer.writeln(_formatRawLogLine(sub, subMs));
        continue;
      }

      final step = _buildStep(sub, subMs);
      final routing = _hookRoutingFromLogSubEntry(
        runtime: runtime,
        sub: sub,
      );
      final pointer = _appendStepByRouting(
        runtime: runtime,
        routing: routing,
        step: step,
      );
      _lastStepPointerByLogEntryId[logEntryId] = pointer;
      _lastOpenStepPointerByRuntimeUuid[runtime.uuid] = pointer;
      if (errorSignature != null) {
        runtime.errorSignatures.add(errorSignature);
      }
      runtime.logBuffer.writeln(_formatRawLogLine(sub, subMs));
      if (_isHttpCheckMarker(sub)) {
        runtime.pendingHttpCheckPointer = pointer;
        hasHttpCheckMarker = true;
      }
    }

    if (!hasHttpCheckMarker) {
      runtime.pendingHttpCheckPointer = null;
    }

    _drainPendingSnapshots(logEntryId, request.testName);
    if (wasFinished) {
      _rewriteFinalizedRuntime(runtime);
    }
  }

  Future<void> _handleRunnerStateChange(RunnerStateChange request) async {
    if (_isServiceTestName(request.testName)) return;

    final runtime = _ensureActiveRuntime(request.testName);

    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    runtime.touchAt(nowMs);
    runtime.status = _mergeRuntimeStatus(
      current: runtime.status,
      incoming: _allureStatusFromResult(request.state.result),
    );

    if (request.state.status == 'complete') {
      await _finalize(runtime);
    }
  }

  void _handleRunnerError(RunnerError request) {
    if (_isSetUpAllServiceTestName(request.testName)) {
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      _deferredSetUpAllSteps.add(
        _buildExceptionStep(
          error: request.error,
          stackTrace: request.stackTrace,
          atMs: nowMs,
          status: 'broken',
        ),
      );
      _deferredSetUpAllLogBuffer.writeln('RUNNER ERROR: ${request.error}');
      if (request.stackTrace.isNotEmpty) {
        _deferredSetUpAllLogBuffer.writeln(request.stackTrace);
      }
      return;
    }
    if (_isServiceTestName(request.testName)) return;

    final runtime = _runtimeForIncomingEvent(request.testName);
    final wasFinished = runtime.finished;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    runtime.touchAt(nowMs);
    final runnerErrorStatus = _statusForRunnerError(request);
    runtime.status = _mergeRuntimeStatus(
      current: runtime.status,
      incoming: runnerErrorStatus,
    );

    if (_shouldSkipRunnerErrorStep(runtime, request)) {
      runtime.logBuffer.writeln('RUNNER ERROR: ${request.error}');
      if (request.stackTrace.isNotEmpty) {
        runtime.logBuffer.writeln(request.stackTrace);
      }
      if (wasFinished) {
        _rewriteFinalizedRuntime(runtime);
      }
      return;
    }

    final errorSignature = _errorSignature(
      message: request.error,
      trace: request.stackTrace,
    );
    if (errorSignature != null &&
        runtime.errorSignatures.contains(errorSignature)) {
      runtime.logBuffer.writeln('RUNNER ERROR: ${request.error}');
      if (request.stackTrace.isNotEmpty) {
        runtime.logBuffer.writeln(request.stackTrace);
      }
      if (wasFinished) {
        _rewriteFinalizedRuntime(runtime);
      }
      return;
    }

    runtime.statusDetails = {
      'message': request.error,
      'trace': request.stackTrace,
    };
    final prevPointer = _lastOpenStepPointerByRuntimeUuid.remove(runtime.uuid);
    if (prevPointer != null) {
      _closeStepPointer(
        runtime: runtime,
        pointer: prevPointer,
        stopMs: nowMs,
      );
    }
    runtime.steps.add(
      _buildExceptionStep(
        error: request.error,
        stackTrace: request.stackTrace,
        atMs: nowMs,
        status: runnerErrorStatus,
      ),
    );
    if (errorSignature != null) {
      runtime.errorSignatures.add(errorSignature);
    }
    runtime.logBuffer.writeln('RUNNER ERROR: ${request.error}');
    if (request.stackTrace.isNotEmpty) {
      runtime.logBuffer.writeln(request.stackTrace);
    }
    if (wasFinished) {
      _rewriteFinalizedRuntime(runtime);
    }
  }

  void _handleRunnerMessage(RunnerMessage request) {
    final customTags = _parseAllureTagsMarker(request.message);
    if (customTags != null) {
      if (_isSetUpAllServiceTestName(request.testName) ||
          _isServiceTestName(request.testName)) {
        return;
      }
      final runtime = _runtimeForIncomingEvent(request.testName);
      runtime.customTags.addAll(customTags);
      if (runtime.finished) {
        _rewriteFinalizedRuntime(runtime);
      }
      return;
    }
    if (_isSetUpAllServiceTestName(request.testName)) {
      _deferredSetUpAllLogBuffer.writeln('RUNNER MESSAGE: ${request.message}');
      return;
    }
    if (_isServiceTestName(request.testName)) return;

    final runtime = _runtimeForIncomingEvent(request.testName);
    final wasFinished = runtime.finished;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    runtime.touchAt(nowMs);
    runtime.logBuffer.writeln('RUNNER MESSAGE: ${request.message}');
    if (wasFinished) {
      _rewriteFinalizedRuntime(runtime);
    }
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

    final openPointer = _lastOpenStepPointerByRuntimeUuid.remove(runtime.uuid);
    if (openPointer != null) {
      _closeStepPointer(
        runtime: runtime,
        pointer: openPointer,
        stopMs: runtime.stopMs,
      );
    }

    await _attachRecordedVideosToRuntime(runtime);

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
    labels.addAll(runtime.customTags.map((e) => {'name': 'tag', 'value': e}));

    final result = <String, dynamic>{
      'uuid': runtime.uuid,
      'historyId': runtime.historyId,
      'name': displayName,
      'fullName': displayName,
      'status': _effectiveRuntimeStatus(runtime),
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
    if (_shouldIncludeRuntimeStatusDetails(runtime)) {
      result['statusDetails'] = runtime.statusDetails;
    }

    await _removePreviousResultForHistoryId(runtime.historyId);

    final resultFileName = '${runtime.uuid}-result.json';
    final resultPath = '$_resultsDirPath$resultFileName';
    File(resultPath).writeAsStringSync(jsonEncode(result), flush: true);
    runtime.resultPath = resultPath;
    await _writeContainer(runtime);

    final active = _activeRuntimeByTestName[runtime.testName];
    if (identical(active, runtime)) {
      _activeRuntimeByTestName.remove(runtime.testName);
    }
  }

  List<Map<String, String>> _suiteLabelsForTest(String testName) {
    final normalized =
        _compactGroupHierarchyNames(_suiteGroupNamesForTest(testName));
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
    // TestOps Features view uses `feature` as the visible root level, so keep
    // the top-most group there to preserve the expected hierarchy.
    addLabel('epic', normalized.first);
    addLabel('feature', normalized.first);
    if (normalized.length >= 2) {
      addLabel('story', normalized.sublist(1).join(' / '));
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
    final raw = () {
      if (suiteInfo == null) return testName;
      final entryId = _resolveSuiteEntryIdForTestName(suiteInfo, testName);
      if (entryId == null) return testName;
      final entry = suiteInfo.entryMap[entryId];
      if (entry is TestInfo && entry.name.trim().isNotEmpty) {
        return entry.name.trim();
      }
      return testName;
    }();
    return _stripGroupPrefixFromDisplayName(
      rawDisplayName: raw,
      suiteGroupNames:
          _compactGroupHierarchyNames(_suiteGroupNamesForTest(testName)),
    );
  }

  String _stripGroupPrefixFromDisplayName({
    required String rawDisplayName,
    required List<String> suiteGroupNames,
  }) {
    var ans = rawDisplayName.trim();
    if (ans.isEmpty || suiteGroupNames.isEmpty) return ans;

    final orderedGroups = suiteGroupNames.toList()
      ..sort((a, b) => b.length.compareTo(a.length));

    var changed = true;
    while (changed) {
      changed = false;
      for (final groupName in orderedGroups) {
        final prefix = groupName.trim();
        if (prefix.isEmpty) continue;
        if (ans.length <= prefix.length) continue;
        if (ans.startsWith('$prefix ')) {
          ans = ans.substring(prefix.length).trimLeft();
          changed = true;
          break;
        }
      }
    }
    return ans;
  }

  void _decorateSetupFixtureByGroups({
    required _AllureTestRuntime runtime,
    required List<String> suiteGroupNames,
  }) {
    final setupFixture = runtime.beforeFixtures['SETUP'];
    if (setupFixture == null) return;

    final visibleSteps = setupFixture.steps.where((step) {
      final stepNameRaw = (step['name'] as String?)?.trim() ?? '';
      return !_isSetupSeparatorStep(stepNameRaw);
    }).toList();

    if (visibleSteps.isEmpty) {
      setupFixture.steps.clear();
      return;
    }

    if (visibleSteps.length == 1) {
      setupFixture.steps
        ..clear()
        ..addAll(visibleSteps);
      return;
    }

    final compactedGroupNames = _compactGroupHierarchyNames(suiteGroupNames);
    final blocks = <List<Map<String, dynamic>>>[];
    var currentBlock = <Map<String, dynamic>>[];
    for (final step in visibleSteps) {
      final stepNameRaw = (step['name'] as String?)?.trim() ?? '';
      if (_isSetupSeparatorStep(stepNameRaw) && currentBlock.isNotEmpty) {
        blocks.add(currentBlock);
        currentBlock = <Map<String, dynamic>>[];
        continue;
      }
      if (_isSetupSeparatorStep(stepNameRaw)) {
        continue;
      }
      currentBlock.add(step);
    }
    if (currentBlock.isNotEmpty) {
      blocks.add(currentBlock);
    }
    if (blocks.length <= 1) {
      setupFixture.steps
        ..clear()
        ..addAll(visibleSteps);
      return;
    }

    final wrappers = <Map<String, dynamic>>[];
    final offset = max(0, compactedGroupNames.length - blocks.length);
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final start = (block.first['start'] as int?) ?? runtime.startMs;
      final stop = (block.last['stop'] as int?) ?? runtime.stopMs;
      final groupName = (i + offset < compactedGroupNames.length)
          ? compactedGroupNames[i + offset]
          : 'group-${i + 1}';
      final hasFailed = block.any((e) =>
          (e['status'] as String?) == 'failed' ||
          (e['status'] as String?) == 'broken');
      wrappers.add({
        'name': groupName,
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

  bool _isSetupSeparatorStep(String rawName) {
    final name = rawName.trim().toUpperCase();
    if (name == 'SETUP') return true;
    if (name.startsWith('SETUP ')) return true;
    if (name.startsWith('SETUP[')) return true;
    if (name.startsWith('SETUP(')) return true;
    return false;
  }

  List<String> _compactGroupHierarchyNames(List<String> rawGroupNames) {
    if (rawGroupNames.isEmpty) return const [];
    final compacted = <String>[];
    for (final raw in rawGroupNames) {
      var name = raw.trim();
      if (name.isEmpty) continue;
      for (final parent in compacted) {
        final prefix = parent.trim();
        if (prefix.isEmpty) continue;
        if (name.length > prefix.length && name.startsWith('$prefix ')) {
          name = name.substring(prefix.length).trimLeft();
          break;
        }
      }
      compacted.add(name);
    }
    return compacted;
  }

  Future<void> _attachRecordedVideosToRuntime(
      _AllureTestRuntime runtime) async {
    final candidates = await _collectVideoCandidates(includeConsumed: false);
    if (candidates.isEmpty) return;
    final matched =
        _matchVideosForRuntime(runtime: runtime, candidates: candidates);

    for (var i = 0; i < matched.length; i++) {
      final file = matched[i];
      final extension = _pathExtension(file.path);
      final source = _nextArtifactName('attachment', extension);
      final targetPath = '$_resultsDirPath$source';
      await file.copy(targetPath);

      runtime.attachments.add({
        'name': matched.length == 1 ? 'video' : 'video-${i + 1}',
        'source': source,
        'type': _videoMimeTypeForExtension(extension),
      });
      _consumedVideoAttachmentPaths.add(file.path);
    }
  }

  Future<List<File>> _collectVideoCandidates({
    required bool includeConsumed,
  }) async {
    final videoDirPath =
        await GetIt.I.get<FsService>().getActiveSuperRunDataSubDirectory(
              category: 'Video',
            );
    final videoDir = Directory(videoDirPath);
    if (!videoDir.existsSync()) return const [];

    final candidates = <File>[];
    for (final entry in videoDir.listSync(followLinks: false)) {
      if (entry is! File) continue;
      if (!includeConsumed &&
          _consumedVideoAttachmentPaths.contains(entry.path)) {
        continue;
      }
      final lower = entry.path.toLowerCase();
      if (!(lower.endsWith('.mov') ||
          lower.endsWith('.mp4') ||
          lower.endsWith('.mkv') ||
          lower.endsWith('.webm'))) {
        continue;
      }
      candidates.add(entry);
    }
    candidates.sort((a, b) {
      final aMs = a.statSync().modified.toUtc().millisecondsSinceEpoch;
      final bMs = b.statSync().modified.toUtc().millisecondsSinceEpoch;
      return aMs.compareTo(bMs);
    });
    return candidates;
  }

  List<File> _matchVideosForRuntime({
    required _AllureTestRuntime runtime,
    required List<File> candidates,
  }) {
    const leadLagToleranceMs = 5 * 60 * 1000;
    final matched = <File>[];
    for (final file in candidates) {
      final stat = file.statSync();
      final endMs = stat.modified.toUtc().millisecondsSinceEpoch;
      final startHintMs = _videoStartHintMsFromPath(file.path);
      final overlaps = endMs >= runtime.startMs - leadLagToleranceMs &&
          (startHintMs ?? endMs) <= runtime.stopMs + leadLagToleranceMs;
      if (overlaps) {
        matched.add(file);
      }
    }

    if (matched.isNotEmpty) return matched;

    final nearest = candidates
        .map((f) => MapEntry(
              f,
              (f.statSync().modified.toUtc().millisecondsSinceEpoch -
                      runtime.stopMs)
                  .abs(),
            ))
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    if (nearest.isNotEmpty && nearest.first.value <= 60 * 1000) {
      return [nearest.first.key];
    }
    return const [];
  }

  Future<void> _backfillVideosForFinishedTests() async {
    final resultsDirPath = _resultsDirPath;
    if (resultsDirPath == null) return;

    final candidates = await _collectVideoCandidates(includeConsumed: true);
    if (candidates.isEmpty) return;

    for (final runtime in _runtimeByUuid.values) {
      if (!runtime.finished) continue;
      final resultPath = runtime.resultPath;
      if (resultPath == null || resultPath.isEmpty) continue;
      if (runtime.attachments
          .any((e) => (e['type'] as String?)?.startsWith('video/') == true)) {
        continue;
      }

      final matched =
          _matchVideosForRuntime(runtime: runtime, candidates: candidates);
      if (matched.isEmpty) continue;

      final resultFile = File(resultPath);
      if (!resultFile.existsSync()) continue;

      final decoded =
          jsonDecode(resultFile.readAsStringSync()) as Map<String, dynamic>;
      final resultAttachments =
          ((decoded['attachments'] as List?) ?? const <dynamic>[])
              .cast<Map<String, dynamic>>()
              .toList();
      if (resultAttachments
          .any((e) => (e['type'] as String?)?.startsWith('video/') == true)) {
        continue;
      }

      for (var i = 0; i < matched.length; i++) {
        final file = matched[i];
        final extension = _pathExtension(file.path);
        final source = _nextArtifactName('attachment', extension);
        final targetPath = '$resultsDirPath$source';
        await file.copy(targetPath);
        final attachment = {
          'name': matched.length == 1 ? 'video' : 'video-${i + 1}',
          'source': source,
          'type': _videoMimeTypeForExtension(extension),
        };
        runtime.attachments.add(attachment);
        resultAttachments.add(attachment);
      }

      decoded['attachments'] = resultAttachments;
      resultFile.writeAsStringSync(jsonEncode(decoded), flush: true);
      Log.i(
        _kTag,
        'video backfill applied testName=${runtime.testName} '
        'videos=${matched.length} resultPath=$resultPath',
      );
    }
  }

  int? _videoStartHintMsFromPath(String path) {
    final fileName = path.split(Platform.pathSeparator).isEmpty
        ? path
        : path.split(Platform.pathSeparator).last;
    final match = RegExp(r'(\d{8}_\d{6})').firstMatch(fileName);
    if (match == null) return null;

    final token = match.group(1);
    if (token == null) return null;
    try {
      final y = int.parse(token.substring(0, 4));
      final m = int.parse(token.substring(4, 6));
      final d = int.parse(token.substring(6, 8));
      final hh = int.parse(token.substring(9, 11));
      final mm = int.parse(token.substring(11, 13));
      final ss = int.parse(token.substring(13, 15));
      return DateTime(y, m, d, hh, mm, ss).toUtc().millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  String _pathExtension(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return 'bin';
    return path.substring(dot + 1).toLowerCase();
  }

  String _videoMimeTypeForExtension(String extension) {
    switch (extension) {
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      default:
        return 'application/octet-stream';
    }
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
    _latestRuntimeByTestName[testName] = runtime;
    _injectDeferredSetUpAllDataIfNeeded(runtime);
    return runtime;
  }

  _AllureTestRuntime _runtimeForIncomingEvent(String testName) {
    final active = _activeRuntimeByTestName[testName];
    if (active != null) {
      return active;
    }
    final latest = _latestRuntimeByTestName[testName];
    if (latest != null) {
      return latest;
    }
    return _ensureActiveRuntime(testName);
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
    if (_isExceptionLikeLogSubEntry(sub)) {
      final message = _exceptionLikeMessage(sub);
      final trace = _exceptionLikeTrace(sub);
      final details = <String>[
        if (message.trim().isNotEmpty) message.trim(),
        if (trace.trim().isNotEmpty) trace.trim(),
      ].join('\n\n');
      if (details.trim().isNotEmpty) {
        step['attachments'] = [
          _writeTextAttachment(
            name: 'exception',
            content: details,
          ),
        ];
      }
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

  bool _isPureHttpLogEntry(LogEntry request) {
    if (request.subEntries.isEmpty) return false;
    return request.subEntries.every((sub) => _isHttpTitle(sub.title));
  }

  bool _isTextAttachmentMarker(LogSubEntry sub) {
    return sub.title.startsWith(_kTextAttachmentTitlePrefix);
  }

  String _textAttachmentName(LogSubEntry sub) {
    final raw = sub.title.substring(_kTextAttachmentTitlePrefix.length).trim();
    return raw.isEmpty ? 'attachment' : raw;
  }

  List<String>? _parseAllureTagsMarker(String message) {
    if (!message.startsWith(_kAllureTagsPrefix)) return null;
    final raw = message.substring(_kAllureTagsPrefix.length).trim();
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  bool _isHttpTitle(String title) {
    final upper = title.trim().toUpperCase();
    return upper.startsWith('HTTP');
  }

  bool _isHttpCheckMarker(LogSubEntry sub) {
    return sub.title.trim().toUpperCase() == 'HTTP CHECK';
  }

  void _attachHttpLogEntryToPendingCheck({
    required _AllureTestRuntime runtime,
    required LogEntry request,
  }) {
    final parentPointer = runtime.pendingHttpCheckPointer;
    if (parentPointer == null || request.subEntries.isEmpty) return;

    final parentSteps = _stepsForPointer(runtime, parentPointer);
    if (parentSteps == null ||
        parentPointer.index < 0 ||
        parentPointer.index >= parentSteps.length) {
      runtime.pendingHttpCheckPointer = null;
      return;
    }

    final nestedStep = _buildHttpDiagnosticStep(request);
    final parentStep = parentSteps[parentPointer.index];
    final nestedSteps =
        (parentStep['steps'] as List?)?.cast<Map<String, dynamic>>() ??
            <Map<String, dynamic>>[];
    nestedSteps.add(nestedStep);
    parentStep['steps'] = nestedSteps;

    final nestedStart = (nestedStep['start'] as int?) ?? runtime.startMs;
    final nestedStop = (nestedStep['stop'] as int?) ?? nestedStart;
    final parentStart = (parentStep['start'] as int?) ?? nestedStart;
    final parentStop = (parentStep['stop'] as int?) ?? nestedStop;
    parentStep['start'] = min(parentStart, nestedStart);
    parentStep['stop'] = max(parentStop, nestedStop);

    final nestedStatus = (nestedStep['status'] as String?) ?? 'passed';
    if (nestedStatus == 'failed' || nestedStatus == 'broken') {
      parentStep['status'] = 'failed';
    }

    if (_isTerminalHttpLogEntry(request)) {
      runtime.pendingHttpCheckPointer = null;
    }
  }

  void _handleDeferredTextAttachment({
    required int logEntryId,
    required LogSubEntry sub,
  }) {
    final attachmentName = _textAttachmentName(sub);
    final stepIndex = _deferredSetUpAllLastStepIndexByLogEntryId[logEntryId];
    if (stepIndex != null) {
      _attachTextToStep(
        steps: _deferredSetUpAllSteps,
        stepIndex: stepIndex,
        name: attachmentName,
        content: sub.message,
      );
      return;
    }

    _deferredSetUpAllTextAttachments.add(
      _PendingTextAttachment(
        name: attachmentName,
        content: sub.message,
      ),
    );
  }

  void _attachTextAttachmentToCurrentContext({
    required _AllureTestRuntime runtime,
    required int logEntryId,
    required LogSubEntry sub,
  }) {
    final attachmentName = _textAttachmentName(sub);
    final pointer = _lastStepPointerByLogEntryId[logEntryId] ??
        _lastOpenStepPointerByRuntimeUuid[runtime.uuid];
    if (pointer == null) {
      runtime.attachments.add(
        _writeTextAttachment(
          name: attachmentName,
          content: sub.message,
        ),
      );
      return;
    }

    final steps = _stepsForPointer(runtime, pointer);
    if (steps == null) {
      runtime.attachments.add(
        _writeTextAttachment(
          name: attachmentName,
          content: sub.message,
        ),
      );
      return;
    }

    _attachTextToStep(
      steps: steps,
      stepIndex: pointer.index,
      name: attachmentName,
      content: sub.message,
    );
  }

  Map<String, dynamic> _buildHttpDiagnosticStep(LogEntry request) {
    final firstSub = request.subEntries.first;
    final startMs = _usToMs(firstSub.time.toInt());
    final stopMs = _usToMs(request.subEntries.last.time.toInt());
    final title = _normalizeHttpDiagnosticTitle(firstSub.title.trim());
    final step = <String, dynamic>{
      'name': title,
      'status': _statusForHttpDiagnosticEntry(request),
      'stage': 'finished',
      'start': startMs,
      'stop': max(startMs, stopMs),
    };

    final attachmentText = request.subEntries
        .map(_formatHttpDiagnosticSubEntry)
        .where((chunk) => chunk.trim().isNotEmpty)
        .join('\n\n');
    if (attachmentText.trim().isNotEmpty) {
      step['attachments'] = [
        _writeTextAttachment(
          name: 'http-log',
          content: attachmentText,
        ),
      ];
    }

    return step;
  }

  String _normalizeHttpDiagnosticTitle(String title) {
    final requestMatch =
        RegExp(r'^HTTP(?:\s+#\d+)?\s+➡️\s+(?<rest>.+)$').firstMatch(title);
    if (requestMatch != null) {
      return 'HTTP request ${requestMatch.namedGroup('rest')!.trim()}';
    }

    final responseMatch =
        RegExp(r'^HTTP(?:\s+#\d+)?\s+⬅️\s+(?<rest>.+)$').firstMatch(title);
    if (responseMatch != null) {
      return 'HTTP response ${responseMatch.namedGroup('rest')!.trim()}';
    }

    return title;
  }

  String _statusForHttpDiagnosticEntry(LogEntry request) {
    for (final sub in request.subEntries) {
      final upper = sub.title.toUpperCase();
      final responseMatch =
          RegExp(r'⬅️\s+(?<status>[0-9]+|[A-Z_]+(?:\s+ERROR)?)')
              .firstMatch(upper);
      if (responseMatch != null) {
        final rawStatus = responseMatch.namedGroup('status') ?? '';
        final statusCode = int.tryParse(rawStatus.split(' ').first);
        if (statusCode != null) {
          return statusCode >= 400 ? 'failed' : 'passed';
        }
        if (rawStatus.contains('ERROR')) {
          return 'failed';
        }
      }
      if (sub.error.isNotEmpty || sub.stackTrace.isNotEmpty) {
        return 'failed';
      }
    }
    return 'passed';
  }

  Map<String, dynamic> _buildExceptionStep({
    required String error,
    required String stackTrace,
    required int atMs,
    required String status,
  }) {
    final details = <String>[
      if (error.trim().isNotEmpty) error.trim(),
      if (stackTrace.trim().isNotEmpty) stackTrace.trim(),
    ].join('\n\n');

    final step = <String, dynamic>{
      'name': 'EXCEPTION',
      'status': status,
      'stage': 'finished',
      'start': atMs,
      'stop': atMs,
    };

    if (details.trim().isNotEmpty) {
      step['attachments'] = [
        _writeTextAttachment(
          name: 'exception',
          content: details,
        ),
      ];
    }

    return step;
  }

  bool _isTerminalHttpLogEntry(LogEntry request) {
    return request.subEntries.any((sub) => sub.title.contains('⬅️'));
  }

  String _formatHttpDiagnosticSubEntry(LogSubEntry sub) {
    final buffer =
        StringBuffer(_normalizeHttpDiagnosticTitle(sub.title.trim()));
    final message = sub.message.trim();
    if (message.isNotEmpty) {
      buffer
        ..writeln()
        ..write(message);
    }
    if (sub.error.isNotEmpty) {
      buffer
        ..writeln()
        ..write('ERROR: ${sub.error}');
    }
    if (sub.stackTrace.isNotEmpty) {
      buffer
        ..writeln()
        ..write('STACK: ${sub.stackTrace}');
    }
    return buffer.toString();
  }

  Map<String, dynamic> _writeTextAttachment({
    required String name,
    required String content,
  }) {
    final source = _nextArtifactName('attachment', 'txt');
    final path = '$_resultsDirPath$source';
    File(path).writeAsStringSync(content, flush: true);
    return {
      'name': name,
      'source': source,
      'type': 'text/plain',
    };
  }

  void _attachTextToStep({
    required List<Map<String, dynamic>> steps,
    required int stepIndex,
    required String name,
    required String content,
  }) {
    if (stepIndex < 0 || stepIndex >= steps.length) return;
    final step = steps[stepIndex];
    final attachments =
        (step['attachments'] as List?)?.cast<Map<String, dynamic>>() ??
            <Map<String, dynamic>>[];
    attachments.add(
      _writeTextAttachment(
        name: name,
        content: content,
      ),
    );
    step['attachments'] = attachments;
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
    for (final attachment in _deferredSetUpAllTextAttachments) {
      beforeFixture.attachments.add(
        _writeTextAttachment(
          name: attachment.name,
          content: attachment.content,
        ),
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

  void _closeStepPointer({
    required _AllureTestRuntime runtime,
    required _AllureStepPointer pointer,
    required int stopMs,
  }) {
    final steps = _stepsForPointer(runtime, pointer);
    if (steps == null) return;
    if (pointer.index < 0 || pointer.index >= steps.length) return;
    final step = steps[pointer.index];
    final start = (step['start'] as int?) ?? stopMs;
    step['stop'] = max(start, stopMs);
  }

  String _formatStepName(LogSubEntry sub) {
    final title = sub.title.trim();
    final message = sub.message.trim();
    if (title.isEmpty) return message.isEmpty ? sub.type.name : message;
    if (message.isEmpty) return title;
    return '$title $message';
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
            (hasExceptionAttachment ||
                message.isNotEmpty ||
                trace.isNotEmpty)) {
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
    bool hasFailed = false;

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

  Future<void> _clearLocalAllureArtifacts({bool clearResults = false}) async {
    await _ensureActiveRunContext();
    await _clearAllureResults();

    final reportDirPath =
        await GetIt.I.get<FsService>().getActiveSuperRunDataSubDirectory(
              category: 'AllureReport',
            );
    final reportDir = Directory(reportDirPath);
    if (reportDir.existsSync()) {
      await reportDir.delete(recursive: true);
    }
    await reportDir.create(recursive: true);

    if (!clearResults) {
      Log.i(
        _kTag,
        'local allure history cleared (results and report reset together)',
      );
    }
  }

  Future<void> _removePreviousResultForHistoryId(String historyId) async {
    final resultsDirPath = _resultsDirPath;
    if (resultsDirPath == null || historyId.trim().isEmpty) return;
    final resultsDir = Directory(resultsDirPath);
    if (!resultsDir.existsSync()) return;

    final targetUuids = <String>{};
    final resultFiles = resultsDir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('-result.json'))
        .toList();
    for (final file in resultFiles) {
      try {
        final decoded = jsonDecode(file.readAsStringSync());
        if (decoded is! Map<String, dynamic>) continue;
        final candidateHistoryId = (decoded['historyId'] as String?)?.trim();
        final candidateUuid = (decoded['uuid'] as String?)?.trim();
        if (candidateHistoryId == historyId &&
            candidateUuid != null &&
            candidateUuid.isNotEmpty) {
          targetUuids.add(candidateUuid);
          await file.delete();
        }
      } catch (_) {
        // Ignore malformed leftovers.
      }
    }
    if (targetUuids.isEmpty) return;

    final containerFiles = resultsDir
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => f.path.endsWith('-container.json'))
        .toList();
    for (final container in containerFiles) {
      try {
        final decoded = jsonDecode(container.readAsStringSync());
        if (decoded is! Map<String, dynamic>) continue;
        final children = ((decoded['children'] as List?) ?? const <dynamic>[])
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .toSet();
        if (children.any(targetUuids.contains)) {
          await container.delete();
        }
      } catch (_) {
        // Ignore malformed leftovers.
      }
    }
  }

  Future<void> _writeContainer(_AllureTestRuntime runtime) async {
    if (_resultsDirPath == null) return;
    final befores = runtime.beforeFixtures.values
        .where((e) => e.hasRenderableContent)
        .map((e) => e.toJson())
        .toList();
    final afters = runtime.afterFixtures.values
        .where((e) => e.hasRenderableContent)
        .map((e) => e.toJson())
        .toList();
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

  void _rewriteFinalizedRuntime(_AllureTestRuntime runtime) {
    final resultPath = runtime.resultPath;
    if (_resultsDirPath == null || resultPath == null || resultPath.isEmpty) {
      return;
    }

    _rewriteRawLogAttachment(runtime);
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
    labels.addAll(runtime.customTags.map((e) => {'name': 'tag', 'value': e}));

    final result = <String, dynamic>{
      'uuid': runtime.uuid,
      'historyId': runtime.historyId,
      'name': displayName,
      'fullName': displayName,
      'status': _effectiveRuntimeStatus(runtime),
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
    if (_shouldIncludeRuntimeStatusDetails(runtime)) {
      result['statusDetails'] = runtime.statusDetails;
    }

    File(resultPath).writeAsStringSync(jsonEncode(result), flush: true);
  }

  void _rewriteRawLogAttachment(_AllureTestRuntime runtime) {
    if (_resultsDirPath == null || runtime.logBuffer.isEmpty) return;

    Map<String, dynamic>? rawLogAttachment;
    for (final attachment in runtime.attachments) {
      if (attachment['name'] == 'raw-log' &&
          attachment['type'] == 'text/plain') {
        rawLogAttachment = attachment;
        break;
      }
    }

    if (rawLogAttachment == null) {
      final source = _nextArtifactName('attachment', 'txt');
      runtime.attachments.add({
        'name': 'raw-log',
        'source': source,
        'type': 'text/plain',
      });
      rawLogAttachment = runtime.attachments.last;
    }

    final source = rawLogAttachment['source'] as String?;
    if (source == null || source.trim().isEmpty) return;
    final path = '$_resultsDirPath$source';
    File(path).writeAsStringSync(runtime.logBuffer.toString(), flush: true);
  }

  void _resetState() {
    _activeRuntimeByTestName.clear();
    _attemptCountByTestName.clear();
    _latestRuntimeByTestName.clear();
    _runtimeByUuid.clear();
    _testNameByLogEntryId.clear();
    _runtimeUuidByLogEntryId.clear();
    _lastStepPointerByLogEntryId.clear();
    _lastOpenStepPointerByRuntimeUuid.clear();
    _pendingSnapshotsByLogEntryId.clear();
    _deferredSetUpAllSteps.clear();
    _deferredSetUpAllLastStepIndexByLogEntryId.clear();
    _deferredSetUpAllAttachments.clear();
    _deferredSetUpAllTextAttachments.clear();
    _deferredSetUpAllLogBuffer = StringBuffer();
    _deferredSetUpAllInjected = false;
    _suiteInfo = null;
    _consumedVideoAttachmentPaths.clear();
    _artifactCounter = 0;
    _uuidCounter = 0;
  }

  void _resetRuntimeState() {
    _activeRuntimeByTestName.clear();
    _attemptCountByTestName.clear();
    _latestRuntimeByTestName.clear();
    _runtimeByUuid.clear();
    _testNameByLogEntryId.clear();
    _runtimeUuidByLogEntryId.clear();
    _lastStepPointerByLogEntryId.clear();
    _lastOpenStepPointerByRuntimeUuid.clear();
    _pendingSnapshotsByLogEntryId.clear();
    _deferredSetUpAllSteps.clear();
    _deferredSetUpAllLastStepIndexByLogEntryId.clear();
    _deferredSetUpAllAttachments.clear();
    _deferredSetUpAllTextAttachments.clear();
    _deferredSetUpAllLogBuffer = StringBuffer();
    _deferredSetUpAllInjected = false;
    _suiteInfo = null;
    _consumedVideoAttachmentPaths.clear();
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
  final _latestRuntimeByTestName = <String, _AllureTestRuntime>{};
  final _attemptCountByTestName = <String, int>{};
  final _runtimeByUuid = <String, _AllureTestRuntime>{};
  final _testNameByLogEntryId = <int, String>{};
  final _runtimeUuidByLogEntryId = <int, String>{};
  final _lastStepPointerByLogEntryId = <int, _AllureStepPointer>{};
  final _lastOpenStepPointerByRuntimeUuid = <String, _AllureStepPointer>{};
  final _pendingSnapshotsByLogEntryId = <int, List<_PendingSnapshot>>{};
  final _deferredSetUpAllSteps = <Map<String, dynamic>>[];
  final _deferredSetUpAllLastStepIndexByLogEntryId = <int, int>{};
  final _deferredSetUpAllAttachments = <_PendingSnapshot>[];
  final _deferredSetUpAllTextAttachments = <_PendingTextAttachment>[];
  StringBuffer _deferredSetUpAllLogBuffer = StringBuffer();
  bool _deferredSetUpAllInjected = false;
  SuiteInfo? _suiteInfo;
  String? _resultsDirPath;
  String? _lastAutoPublishAttemptedSuperRunId;
  String? _lastAutoPublishedSuperRunId;
  bool _autoPublishInProgress = false;
  int _artifactCounter = 0;
  int _uuidCounter = 0;
  final _consumedVideoAttachmentPaths = <String>{};
  final _lastSuiteInfoDigestBySuperRunId = <String, String>{};
}

class _PendingSnapshot {
  final String name;
  final Uint8List image;

  const _PendingSnapshot({
    required this.name,
    required this.image,
  });
}

class _PendingTextAttachment {
  final String name;
  final String content;

  const _PendingTextAttachment({
    required this.name,
    required this.content,
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
  final Set<String> customTags = {};
  final Set<String> errorSignatures = {};
  final Map<String, _AllureFixtureRuntime> beforeFixtures = {};
  final Map<String, _AllureFixtureRuntime> afterFixtures = {};
  final StringBuffer logBuffer = StringBuffer();
  String? resultPath;
  String? status;
  Map<String, dynamic>? statusDetails;
  _AllureStepPointer? pendingHttpCheckPointer;
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

  bool get hasRenderableContent =>
      _buildDisplaySteps().isNotEmpty || attachments.isNotEmpty;

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
