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

part 'allure_report_service/grouping.dart';
part 'allure_report_service/media.dart';
part 'allure_report_service/models.dart';
part 'allure_report_service/events.dart';
part 'allure_report_service/persistence.dart';
part 'allure_report_service/status.dart';

class ManagerAllureReportService {
  static const _kTag = 'ManagerAllureReportService';
  static const _kGenerateOpenPublishTimeout = Duration(seconds: 20);
  static const _kVideoChunkSnapshotPrefix = '__ct_video_chunk__';
  static const _kTextAttachmentTitlePrefix = '__CT_TEXT_ATTACHMENT__:';
  static const _kAllureTagsPrefix = '__CT_ALLURE_TAGS__:';
  static const _kAllureStepStartPrefix = '__CT_ALLURE_STEP_START__:';
  static const _kAllureStepEndPrefix = '__CT_ALLURE_STEP_END__:';
  static const _kAllureStepParameterPrefix = '__CT_ALLURE_STEP_PARAMETER__:';
  static const _kAllureStepTextAttachmentPrefix =
      '__CT_ALLURE_STEP_TEXT_ATTACHMENT__:';
  static const _kAllureStepJsonAttachmentPrefix =
      '__CT_ALLURE_STEP_JSON_ATTACHMENT__:';
  late final _events = _AllureEventProcessor(this);
  late final _persistence = _AllurePersistence(this);

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

  Future<void> _handleItem(ReportItem item) => _events.handleItem(item);

  Future<void> _finalize(_AllureTestRuntime runtime) =>
      _persistence.finalize(runtime);

  List<Map<String, String>> _suiteLabelsForTest(String testName) =>
      _buildSuiteLabelsForTest(suiteInfo: _suiteInfo, testName: testName);

  List<String> _suiteGroupNamesForTest(String testName) =>
      _suiteGroupNamesForTestInfo(_suiteInfo, testName);

  String _displayNameForTest(String testName) =>
      _displayNameForTestInfo(suiteInfo: _suiteInfo, testName: testName);

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

  Map<String, dynamic>? _parseRunnerMessageJsonMarker(
    String message,
    String prefix,
  ) {
    if (!message.startsWith(prefix)) return null;
    final raw = message.substring(prefix.length).trim();
    if (raw.isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return const <String, dynamic>{};
      }
      return decoded.cast<String, dynamic>();
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  void _handleAllureCustomStepStart({
    required _AllureTestRuntime runtime,
    required Map<String, dynamic> payload,
    required int atMs,
  }) {
    final id = payload['id']?.toString().trim() ?? '';
    final name = payload['name']?.toString().trim() ?? '';
    if (id.isEmpty || name.isEmpty) return;

    final step = <String, dynamic>{
      'name': name,
      'status': 'passed',
      'stage': 'finished',
      'start': atMs,
      'stop': atMs,
    };
    _appendAllureCustomStep(runtime: runtime, id: id, step: step);
  }

  void _handleAllureCustomStepEnd({
    required _AllureTestRuntime runtime,
    required Map<String, dynamic> payload,
    required int atMs,
  }) {
    final id = payload['id']?.toString().trim() ?? '';
    if (id.isEmpty) return;

    final step = runtime.allureStepsById[id];
    if (step == null) return;
    final start = (step['start'] as int?) ?? atMs;
    step['stop'] = max(start, atMs);
    final incomingStatus =
        payload['status']?.toString().trim().toLowerCase() ?? '';
    if (incomingStatus == 'failed' || incomingStatus == 'broken') {
      step['status'] = _mergeRuntimeStatus(
        current: step['status'] as String?,
        incoming: incomingStatus,
      );
      _bubbleCustomStepStatus(
          runtime: runtime, stepId: id, status: incomingStatus);
    } else {
      step['status'] = _mergeRuntimeStatus(
        current: step['status'] as String?,
        incoming: 'passed',
      );
    }
    runtime.openAllureStepIds.remove(id);
  }

  void _handleAllureCustomStepParameter({
    required _AllureTestRuntime runtime,
    required Map<String, dynamic> payload,
  }) {
    final step = _resolveAllureCustomStep(runtime, payload);
    if (step == null) return;
    final name = payload['name']?.toString().trim() ?? '';
    if (name.isEmpty) return;
    final value = payload['value']?.toString() ?? '';
    final parameters =
        (step['parameters'] as List?)?.cast<Map<String, dynamic>>() ??
            <Map<String, dynamic>>[];
    parameters.add({
      'name': name,
      'value': value,
    });
    step['parameters'] = parameters;
  }

  void _handleAllureCustomStepAttachment({
    required _AllureTestRuntime runtime,
    required Map<String, dynamic> payload,
    required String type,
    required String extension,
  }) {
    final step = _resolveAllureCustomStep(runtime, payload);
    if (step == null) return;
    final name = payload['name']?.toString().trim();
    final content = payload['content']?.toString() ?? '';
    if (content.trim().isEmpty) return;
    final attachments =
        (step['attachments'] as List?)?.cast<Map<String, dynamic>>() ??
            <Map<String, dynamic>>[];
    attachments.add(
      _writeStringAttachment(
        name: (name == null || name.isEmpty) ? 'attachment' : name,
        content: content,
        type: type,
        extension: extension,
      ),
    );
    step['attachments'] = attachments;
  }

  Map<String, dynamic>? _resolveAllureCustomStep(
    _AllureTestRuntime runtime,
    Map<String, dynamic> payload,
  ) {
    final id = payload['id']?.toString().trim() ?? '';
    if (id.isNotEmpty) {
      return runtime.allureStepsById[id];
    }
    if (runtime.openAllureStepIds.isEmpty) {
      return null;
    }
    final lastId = runtime.openAllureStepIds.last;
    return runtime.allureStepsById[lastId];
  }

  void _appendAllureCustomStep({
    required _AllureTestRuntime runtime,
    required String id,
    required Map<String, dynamic> step,
  }) {
    if (runtime.openAllureStepIds.isEmpty) {
      runtime.steps.add(step);
    } else {
      final parentId = runtime.openAllureStepIds.last;
      final parent = runtime.allureStepsById[parentId];
      if (parent == null) {
        runtime.steps.add(step);
      } else {
        final nestedSteps =
            (parent['steps'] as List?)?.cast<Map<String, dynamic>>() ??
                <Map<String, dynamic>>[];
        nestedSteps.add(step);
        parent['steps'] = nestedSteps;
        final start = (step['start'] as int?) ?? runtime.startMs;
        final stop = (step['stop'] as int?) ?? start;
        parent['start'] = min((parent['start'] as int?) ?? start, start);
        parent['stop'] = max((parent['stop'] as int?) ?? stop, stop);
      }
    }
    runtime.allureStepsById[id] = step;
    runtime.openAllureStepIds.add(id);
  }

  void _bubbleCustomStepStatus({
    required _AllureTestRuntime runtime,
    required String stepId,
    required String status,
  }) {
    final index = runtime.openAllureStepIds.indexOf(stepId);
    if (index <= 0) return;
    for (var i = index - 1; i >= 0; i--) {
      final parentId = runtime.openAllureStepIds[i];
      final parent = runtime.allureStepsById[parentId];
      if (parent == null) continue;
      parent['status'] = _mergeRuntimeStatus(
        current: parent['status'] as String?,
        incoming: status,
      );
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
    return _writeStringAttachment(
      name: name,
      content: content,
      type: 'text/plain',
      extension: 'txt',
    );
  }

  Map<String, dynamic> _writeStringAttachment({
    required String name,
    required String content,
    required String type,
    required String extension,
  }) {
    final source = _nextArtifactName('attachment', extension);
    final path = '$_resultsDirPath$source';
    File(path).writeAsStringSync(content, flush: true);
    return {
      'name': name,
      'source': source,
      'type': type,
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
          _events.attachSnapshotToStep(
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
        _events.attachSnapshotToRuntime(runtime, pending.name, pending.image);
      } else {
        final steps = _stepsForPointer(runtime, stepPointer);
        if (steps == null) {
          _events.attachSnapshotToRuntime(runtime, pending.name, pending.image);
          continue;
        }
        _events.attachSnapshotToStep(
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
      _events.attachSnapshotToFixture(
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

  Future<void> _ensureActiveRunContext() =>
      _persistence.ensureActiveRunContext();

  Future<void> _clearAllureResults() => _persistence.clearAllureResults();

  Future<void> _clearLocalAllureArtifacts({bool clearResults = false}) =>
      _persistence.clearLocalAllureArtifacts(clearResults: clearResults);

  void _rewriteFinalizedRuntime(_AllureTestRuntime runtime) =>
      _persistence.rewriteFinalizedRuntime(runtime);

  void _resetRuntimeState() => _persistence.resetRuntimeState();

  Future<bool> _openUrlDetached(String url) =>
      _persistence.openUrlDetached(url);

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
