import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/services/fs_service.dart';
import 'package:convenient_test_manager_dart/services/misc_dart_service.dart';
import 'package:convenient_test_manager_dart/services/report_saver_service.dart';
import 'package:convenient_test_manager_dart/stores/allure_custom_step_store.dart';
import 'package:convenient_test_manager_dart/stores/highlight_store.dart';
import 'package:convenient_test_manager_dart/stores/log_store.dart';
import 'package:convenient_test_manager_dart/stores/raw_log_store.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:convenient_test_manager_dart/stores/video_player_store.dart';
import 'package:convenient_test_manager_dart/stores/video_recorder_store.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:crypto/crypto.dart';
import 'package:get_it/get_it.dart';
import 'package:mobx/mobx.dart';

class ReportHandlerService {
  static const _kTag = 'ReportHandlerService';
  static const _kVideoChunkSnapshotPrefix = '__ct_video_chunk__';
  static const _kStaleVideoTolerance = Duration(seconds: 1);
  static const _kTextAttachmentTitlePrefix = '__CT_TEXT_ATTACHMENT__:';
  static const _kAllureTagsPrefix = '__CT_ALLURE_TAGS__:';
  static const _kAllureStepStartPrefix = '__CT_ALLURE_STEP_START__:';
  static const _kAllureStepEndPrefix = '__CT_ALLURE_STEP_END__:';
  static const _kAllureStepParameterPrefix = '__CT_ALLURE_STEP_PARAMETER__:';
  static const _kAllureStepTextAttachmentPrefix =
      '__CT_ALLURE_STEP_TEXT_ATTACHMENT__:';
  static const _kAllureStepJsonAttachmentPrefix =
      '__CT_ALLURE_STEP_JSON_ATTACHMENT__:';
  final _hasSeenBodyStartByTestEntryId = <int, bool>{};

  /// handle a report sent by the worker.
  /// doClear: if handleSuiteInfoProto should clear the already known suite info.
  /// set to false on widget tests.
  Future<void> handle(
    ReportCollection reportCollection, {
    required bool offlineFile,
    bool doClear = true,
  }) async {
    for (final item in reportCollection.items) {
      await _handleItem(item, offlineFile: offlineFile, doClear: doClear);
    }
  }

  Future<void> _handleItem(ReportItem item,
      {required bool offlineFile, required bool doClear}) {
    switch (item.whichSubType()) {
      case ReportItem_SubType.setUpAll:
        return _handleSetUpAll(item.setUpAll, offlineFile: offlineFile);
      case ReportItem_SubType.tearDownAll:
        return _handleTearDownAll(item.tearDownAll, offlineFile: offlineFile);
      case ReportItem_SubType.suiteInfoProto:
        return _handleSuiteInfoProto(item.suiteInfoProto, doClear: doClear);
      case ReportItem_SubType.logEntry:
        return _handleLogEntry(item.logEntry);
      case ReportItem_SubType.runnerStateChange:
        return _handleRunnerStateChange(item.runnerStateChange);
      case ReportItem_SubType.runnerError:
        return _handleRunnerError(item.runnerError);
      case ReportItem_SubType.runnerMessage:
        return _handleRunnerMessage(item.runnerMessage);
      case ReportItem_SubType.snapshot:
        return _handleSnapshot(item.snapshot, offlineFile: offlineFile);
      case ReportItem_SubType.notSet:
        throw Exception('unknown $item');
    }
  }

  Future<void> _handleSetUpAll(SetUpAll request,
      {required bool offlineFile}) async {
    Log.d(_kTag, 'SetUpAll $request');
    if (!offlineFile) {
      Log.i(
          _kTag, 'SetUpAll skip local manager recording (worker-owned video)');
    }
  }

  Future<void> _handleTearDownAll(TearDownAll request,
      {required bool offlineFile}) async {
    Log.d(_kTag, 'TearDownAll $request');
    if (!offlineFile) {
      Log.i(_kTag, 'TearDownAll skip local manager stop (worker-owned video)');

      final executedNames =
          request.resolvedExecutionFilter.allowExecuteTestNames;
      if (executedNames.isEmpty) {
        Log.i(
          _kTag,
          'TearDownAll detected empty/service run; remove current RUN directory',
        );
        await GetIt.I
            .get<ManagerReportSaverService>()
            .clearCurrentSuperRunDataDirectory();
      }
    }

    GetIt.I
        .get<WorkerSuperRunStore>()
        .currSuperRunController
        .handleTearDownAll(request.resolvedExecutionFilter);
  }

  Future<void> _handleLogEntry(LogEntry request) async {
    Log.d(_kTag, 'handleReportLogEntry called');

    final testEntryId =
        _suiteInfoStore.suiteInfo?.getEntryIdFromName(request.testName);
    if (testEntryId == null) {
      Log.i(_kTag,
          'handleReportLogEntry skipped since getEntryIdFromName failed');
      return;
    }

    final requestId = request.id.toInt();
    final visibleSubEntries = request.subEntries
        .where((sub) => !sub.title.startsWith(_kTextAttachmentTitlePrefix))
        .toList(growable: false);
    if (visibleSubEntries.isEmpty) {
      return;
    }

    if (visibleSubEntries.any(
      (sub) => sub.type == LogSubEntryType.TEST_END,
    )) {
      _hasSeenBodyStartByTestEntryId[testEntryId] = false;
    }
    if (visibleSubEntries.any(
      (sub) => sub.type == LogSubEntryType.TEST_START,
    )) {
      _hasSeenBodyStartByTestEntryId[testEntryId] = true;
    }

    _logStore.addLogEntry(
        testEntryId: testEntryId,
        logEntryId: requestId,
        subEntries: visibleSubEntries);

    GetIt.I
        .get<HighlightStoreBase>()
        .handleLogEntry(testEntryId: testEntryId, logEntryId: requestId);
  }

  Future<void> _handleRunnerError(RunnerError request) async {
    Log.d(_kTag, 'Error: ${request.error} stack=${request.stackTrace}');

    final testEntryId =
        _suiteInfoStore.suiteInfo?.getEntryIdFromName(request.testName);
    if (testEntryId == null) return;

    _rawLogStore.rawLogInTest[testEntryId] +=
        '${request.error}\n${request.stackTrace}\n';
  }

  Future<void> _handleRunnerMessage(RunnerMessage request) async {
    Log.d(_kTag, 'Message: ${request.message}');

    final testEntryId =
        _suiteInfoStore.suiteInfo?.getEntryIdFromName(request.testName);
    if (testEntryId != null) {
      final customStepStore = GetIt.I.get<AllureCustomStepStore>();
      final stepStart = _parseRunnerMessageJsonMarker(
          request.message, _kAllureStepStartPrefix);
      if (stepStart != null) {
        final id = stepStart['id']?.toString().trim() ?? '';
        final name = stepStart['name']?.toString().trim() ?? '';
        if (id.isNotEmpty && name.isNotEmpty) {
          customStepStore.startStep(
            testEntryId: testEntryId,
            id: id,
            name: name,
            section: (_hasSeenBodyStartByTestEntryId[testEntryId] ?? false)
                ? AllureCustomStepSection.body
                : AllureCustomStepSection.setup,
          );
        }
        return;
      }
      final stepEnd =
          _parseRunnerMessageJsonMarker(request.message, _kAllureStepEndPrefix);
      if (stepEnd != null) {
        final id = stepEnd['id']?.toString().trim() ?? '';
        final status = stepEnd['status']?.toString().trim().toLowerCase() ?? '';
        if (id.isNotEmpty) {
          customStepStore.endStep(
            testEntryId: testEntryId,
            id: id,
            status: status.isEmpty ? 'passed' : status,
          );
        }
        return;
      }
      final stepParameter = _parseRunnerMessageJsonMarker(
        request.message,
        _kAllureStepParameterPrefix,
      );
      if (stepParameter != null) {
        final id = stepParameter['id']?.toString().trim() ?? '';
        if (id.isNotEmpty) {
          customStepStore.addParameter(id: id);
        }
        return;
      }
      final stepTextAttachment = _parseRunnerMessageJsonMarker(
        request.message,
        _kAllureStepTextAttachmentPrefix,
      );
      if (stepTextAttachment != null) {
        final id = stepTextAttachment['id']?.toString().trim() ?? '';
        if (id.isNotEmpty) {
          customStepStore.addAttachment(id: id);
        }
        return;
      }
      final stepJsonAttachment = _parseRunnerMessageJsonMarker(
        request.message,
        _kAllureStepJsonAttachmentPrefix,
      );
      if (stepJsonAttachment != null) {
        final id = stepJsonAttachment['id']?.toString().trim() ?? '';
        if (id.isNotEmpty) {
          customStepStore.addAttachment(id: id);
        }
        return;
      }
    }

    if (_isControlRunnerMessage(request.message)) {
      return;
    }
    if (testEntryId == null) return;

    _rawLogStore.rawLogInTest[testEntryId] += '${request.message}\n';
  }

  bool _isControlRunnerMessage(String message) {
    return message.startsWith(_kAllureTagsPrefix) ||
        message.startsWith(_kAllureStepStartPrefix) ||
        message.startsWith(_kAllureStepEndPrefix) ||
        message.startsWith(_kAllureStepParameterPrefix) ||
        message.startsWith(_kAllureStepTextAttachmentPrefix) ||
        message.startsWith(_kAllureStepJsonAttachmentPrefix);
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
      if (decoded is! Map) return const <String, dynamic>{};
      return decoded.cast<String, dynamic>();
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Future<void> _handleRunnerStateChange(RunnerStateChange request) async {
    Log.d(_kTag,
        'StateChange: testName=${request.testName} state=${request.state}');

    final testEntryId =
        _suiteInfoStore.suiteInfo?.getEntryIdFromName(request.testName);
    if (testEntryId == null) return;

    _suiteInfoStore.testEntryStateMap[testEntryId] = request.state;
    if (request.state.status == 'complete') {
      _hasSeenBodyStartByTestEntryId[testEntryId] = false;
    }
  }

  Future<void> _handleSnapshot(
    Snapshot request, {
    required bool offlineFile,
  }) async {
    if (await _handleWorkerVideoChunkSnapshot(request,
        offlineFile: offlineFile)) {
      return;
    }

    Log.d(_kTag, 'Snapshot');

    final logEntryId = request.logEntryId.toInt();
    _logStore.snapshotInLog[logEntryId] ??= ObservableMap();
    _logStore.snapshotInLog[logEntryId]![request.name] =
        request.image as Uint8List;
  }

  Future<void> _handleSuiteInfoProto(SuiteInfoProto request,
      {required bool doClear}) async {
    Log.d(_kTag, 'handleReportSuiteInfo called $request');

    final superRunId =
        GetIt.I.get<WorkerSuperRunStore>().currSuperRunController.superRunId;
    final suiteInfoDigest = sha256.convert(request.writeToBuffer()).toString();
    final shouldReset =
        _lastSuiteInfoDigestBySuperRunId[superRunId] != suiteInfoDigest;
    _lastSuiteInfoDigestBySuperRunId[superRunId] = suiteInfoDigest;

    if (shouldReset) {
      Log.d(_kTag, 'handleReportSuiteInfo thus MiscDartService.clearAll');
      GetIt.I.get<MiscDartService>().clearAll();
      _hasSeenBodyStartByTestEntryId.clear();

      // in case data from previous super-run are logged into current run
      if (doClear) {
        Log.d(_kTag, 'handleReportSuiteInfo thus ReportSaverService.clear');
        await GetIt.I.get<ManagerReportSaverService>().clear();
      }
    } else {
      Log.i(
        _kTag,
        'suiteInfo deduplicated for superRunId=$superRunId, skip destructive clear',
      );
    }

    Log.d(_kTag, 'handleReportSuiteInfo set new suitInfo');
    _suiteInfoStore.suiteInfo = SuiteInfo.fromProto(request);
    _currentRunSuiteInfoReceivedAt = DateTime.now().toUtc();

    await _clearPendingIncomingVideoChunks();
  }

  Future<bool> _handleWorkerVideoChunkSnapshot(
    Snapshot request, {
    required bool offlineFile,
  }) async {
    final name = request.name;
    if (!name.startsWith('$_kVideoChunkSnapshotPrefix:')) return false;

    final parts = name.split(':');
    if (parts.length != 7 && parts.length != 9) {
      Log.w(_kTag, 'invalid worker video chunk snapshot name="$name"');
      return true;
    }

    final sessionId = parts[1];
    if (_failedIncomingVideoSessionIds.contains(sessionId)) {
      Log.w(_kTag, 'skip chunk from failed worker video sessionId=$sessionId');
      return true;
    }

    final rawFileName = parts[2];
    final fileName = () {
      try {
        return Uri.decodeComponent(rawFileName);
      } catch (_) {
        return rawFileName;
      }
    }();
    final startMs = int.tryParse(parts[3]);
    final endMs = int.tryParse(parts[4]);
    final chunkIndex = int.tryParse(parts[5]);
    final isLastChunk = parts[6] == '1';
    final totalChunks = parts.length >= 9 ? int.tryParse(parts[7]) : null;
    final expectedSha256 = parts.length >= 9 ? parts[8] : null;
    if (startMs == null || endMs == null || chunkIndex == null) {
      Log.w(_kTag, 'invalid worker video chunk snapshot fields name="$name"');
      await _markWorkerVideoSessionFailed(sessionId);
      return true;
    }
    if (totalChunks != null && totalChunks <= 0) {
      Log.w(_kTag, 'invalid totalChunks=$totalChunks sessionId=$sessionId');
      await _markWorkerVideoSessionFailed(sessionId);
      return true;
    }

    final chunkStartTimeUtc =
        DateTime.fromMillisecondsSinceEpoch(startMs).toUtc();
    final chunkEndTimeUtc = DateTime.fromMillisecondsSinceEpoch(endMs).toUtc();
    if (!offlineFile) {
      final suiteInfoAt = _currentRunSuiteInfoReceivedAt;
      if (suiteInfoAt != null &&
          chunkEndTimeUtc
              .isBefore(suiteInfoAt.subtract(_kStaleVideoTolerance))) {
        Log.w(
          _kTag,
          'drop stale worker video chunk from previous run '
          'sessionId=$sessionId chunkIndex=$chunkIndex '
          'chunkStart=$chunkStartTimeUtc chunkEnd=$chunkEndTimeUtc '
          'suiteInfoAt=$suiteInfoAt',
        );
        await _markWorkerVideoSessionFailed(sessionId);
        return true;
      }
    }

    final chunkData = request.image as Uint8List;
    final videoDir = await GetIt.I
        .get<FsService>()
        .getActiveSuperRunDataSubDirectory(category: 'Video');
    final state = _incomingVideoChunkMap.putIfAbsent(
      sessionId,
      () => _IncomingVideoChunkState(
        tempPath: '$videoDir.__incoming__$sessionId.part',
        fileName: fileName,
        startTime: DateTime.fromMillisecondsSinceEpoch(startMs),
        endTime: DateTime.fromMillisecondsSinceEpoch(endMs),
        totalChunks: totalChunks,
        expectedSha256: expectedSha256,
      ),
    );

    if (state.totalChunks != null &&
        totalChunks != null &&
        state.totalChunks != totalChunks) {
      Log.w(
        _kTag,
        'worker video chunk totalChunks mismatch sessionId=$sessionId '
        'existing=${state.totalChunks} incoming=$totalChunks',
      );
      await _markWorkerVideoSessionFailed(sessionId);
      return true;
    }
    if (state.expectedSha256 != null &&
        expectedSha256 != null &&
        state.expectedSha256 != expectedSha256) {
      Log.w(
        _kTag,
        'worker video chunk sha mismatch sessionId=$sessionId '
        'existing=${state.expectedSha256} incoming=$expectedSha256',
      );
      await _markWorkerVideoSessionFailed(sessionId);
      return true;
    }

    if (chunkIndex != state.nextChunkIndex) {
      Log.w(
        _kTag,
        'worker video chunk out-of-order sessionId=$sessionId '
        'chunkIndex=$chunkIndex expected=${state.nextChunkIndex}',
      );
      await _markWorkerVideoSessionFailed(sessionId);
      return true;
    }

    final tempFile = File(state.tempPath);
    if (chunkData.isNotEmpty) {
      await tempFile.writeAsBytes(chunkData, mode: FileMode.append);
    }
    state.nextChunkIndex = chunkIndex + 1;

    if (state.totalChunks != null &&
        state.nextChunkIndex > state.totalChunks!) {
      Log.w(
        _kTag,
        'worker video chunk exceeds totalChunks sessionId=$sessionId '
        'nextChunkIndex=${state.nextChunkIndex} totalChunks=${state.totalChunks}',
      );
      await _markWorkerVideoSessionFailed(sessionId);
      return true;
    }

    if (!isLastChunk) return true;

    if (state.totalChunks != null && chunkIndex != state.totalChunks! - 1) {
      Log.w(
        _kTag,
        'worker video last-chunk index mismatch sessionId=$sessionId '
        'chunkIndex=$chunkIndex totalChunks=${state.totalChunks}',
      );
      await _markWorkerVideoSessionFailed(sessionId);
      return true;
    }

    final targetPath = await _createUniqueVideoPath(videoDir, state.fileName);
    if (await File(targetPath).exists()) {
      await File(targetPath).delete();
    }
    await tempFile.rename(targetPath);

    final sizeBytes = await File(targetPath).length();
    if (sizeBytes < 4 * 1024) {
      Log.w(
        _kTag,
        'ignore uploaded worker video since too small '
        'sizeBytes=$sizeBytes path=$targetPath',
      );
      await File(targetPath).delete();
    } else {
      if (state.expectedSha256 != null) {
        final actualSha256 =
            sha256.convert(await File(targetPath).readAsBytes()).toString();
        if (actualSha256 != state.expectedSha256) {
          Log.w(
            _kTag,
            'ignore uploaded worker video since sha256 mismatch '
            'expected=${state.expectedSha256} actual=$actualSha256 path=$targetPath',
          );
          await File(targetPath).delete();
          await _markWorkerVideoSessionFailed(sessionId, clearState: false);
          _incomingVideoChunkMap.remove(sessionId);
          return true;
        }
      }

      final info = VideoInfo(
        path: targetPath,
        startTime: state.startTime,
        endTime: state.endTime,
      );
      GetIt.I.get<VideoPlayerStoreBase>().handleRecorderFinished(info);
    }

    _incomingVideoChunkMap.remove(sessionId);
    return true;
  }

  Future<String> _createUniqueVideoPath(
      String videoDir, String fileName) async {
    final dot = fileName.lastIndexOf('.');
    final stem = dot <= 0 ? fileName : fileName.substring(0, dot);
    final ext = dot <= 0 ? '' : fileName.substring(dot);

    var attempt = 0;
    while (true) {
      final suffix = attempt == 0 ? '' : '-$attempt';
      final path = '$videoDir$stem$suffix$ext';
      if (!await File(path).exists()) return path;
      attempt++;
    }
  }

  Future<void> _clearPendingIncomingVideoChunks() async {
    for (final state in _incomingVideoChunkMap.values) {
      final file = File(state.tempPath);
      if (await file.exists()) {
        await file.delete();
      }
    }
    _incomingVideoChunkMap.clear();
    _failedIncomingVideoSessionIds.clear();
  }

  Future<void> _markWorkerVideoSessionFailed(
    String sessionId, {
    bool clearState = true,
  }) async {
    _failedIncomingVideoSessionIds.add(sessionId);
    if (!clearState) return;

    final state = _incomingVideoChunkMap.remove(sessionId);
    if (state == null) return;
    final file = File(state.tempPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  final _logStore = GetIt.I.get<LogStore>();
  final _suiteInfoStore = GetIt.I.get<SuiteInfoStore>();
  final _rawLogStore = GetIt.I.get<RawLogStore>();
  final _lastSuiteInfoDigestBySuperRunId = <String, String>{};
  final _incomingVideoChunkMap = <String, _IncomingVideoChunkState>{};
  final _failedIncomingVideoSessionIds = <String>{};
  DateTime? _currentRunSuiteInfoReceivedAt;
}

class _IncomingVideoChunkState {
  final String tempPath;
  final String fileName;
  final DateTime startTime;
  final DateTime endTime;
  final int? totalChunks;
  final String? expectedSha256;
  int nextChunkIndex = 0;

  _IncomingVideoChunkState({
    required this.tempPath,
    required this.fileName,
    required this.startTime,
    required this.endTime,
    this.totalChunks,
    this.expectedSha256,
  });
}
