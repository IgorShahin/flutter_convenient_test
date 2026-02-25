import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/misc/runtime_platform.dart';
import 'package:convenient_test_manager_dart/services/fs_service.dart';
import 'package:get_it/get_it.dart';

class ManagerAllureReportService {
  static const _kTag = 'ManagerAllureReportService';
  static const _kVideoChunkSnapshotPrefix = '__ct_video_chunk__';

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

    await _ensureActiveRunContext();
    final resultsDirPath = _resultsDirPath;
    final reportDirPath = _reportDirPath;
    if (resultsDirPath == null || reportDirPath == null) return;

    final resultsDir = Directory(resultsDirPath);
    if (!resultsDir.existsSync()) {
      Log.w(_kTag, 'allure-results directory not found path=$resultsDirPath');
      return;
    }
    final hasResults = resultsDir
        .listSync()
        .whereType<File>()
        .any((f) => f.path.endsWith('-result.json'));
    if (!hasResults) {
      Log.w(_kTag, 'allure-results has no test results path=$resultsDirPath');
      return;
    }

    await _hydrateHistoryIntoResults();

    ProcessResult pr;
    try {
      pr = await Process.run(
        'allure',
        ['generate', resultsDirPath, '-o', reportDirPath, '--clean'],
        runInShell: true,
      ).timeout(const Duration(minutes: 2));
    } on TimeoutException {
      Log.e(
        _kTag,
        'allure generate timeout (>2m). '
        'resultsDirPath=$resultsDirPath reportDirPath=$reportDirPath',
      );
      return;
    }
    if (pr.exitCode != 0) {
      Log.e(
        _kTag,
        'allure generate failed exitCode=${pr.exitCode} '
        'stdout=${pr.stdout} stderr=${pr.stderr}',
      );
      return;
    }

    await _persistHistoryFromReportDir();

    final started = await _startAllureOpenDetached(reportDirPath);
    if (!started) return;
    Log.i(_kTag, 'allure report opened via local server dir=$reportDirPath');
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
      for (final sub in request.subEntries) {
        final subMs = _usToMs(sub.time.toInt());
        final step = _buildStep(sub, subMs);
        _deferredSetUpAllSteps.add(step);
        _deferredSetUpAllLogBuffer.writeln(_formatRawLogLine(sub, subMs));
      }
      _drainPendingSnapshots(logEntryId, request.testName);
      return;
    }
    if (_isServiceTestName(request.testName)) return;

    final runtime = _ensureTestRuntime(request.testName);

    for (final sub in request.subEntries) {
      final subMs = _usToMs(sub.time.toInt());
      runtime.touchAt(subMs);

      runtime.steps.add(_buildStep(sub, subMs));
      runtime.logBuffer.writeln(_formatRawLogLine(sub, subMs));
    }

    _drainPendingSnapshots(logEntryId, request.testName);
  }

  Future<void> _handleRunnerStateChange(RunnerStateChange request) async {
    if (_isServiceTestName(request.testName)) return;

    final runtime = _ensureTestRuntime(request.testName);

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

    final runtime = _ensureTestRuntime(request.testName);
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

    final runtime = _ensureTestRuntime(request.testName);
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
      _deferredSetUpAllAttachments.add(
        _PendingSnapshot(name: request.name, image: request.image as Uint8List),
      );
      return;
    }
    if (_isServiceTestName(testName)) return;

    final runtime = _ensureTestRuntime(testName);
    _attachSnapshotToRuntime(runtime, request.name, request.image as Uint8List);
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
    };
    if (runtime.statusDetails != null) {
      result['statusDetails'] = runtime.statusDetails;
    }

    final resultFileName = '${runtime.uuid}-result.json';
    final resultPath = '$_resultsDirPath$resultFileName';
    File(resultPath).writeAsStringSync(jsonEncode(result), flush: true);
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

  _AllureTestRuntime _ensureTestRuntime(String testName) {
    final runtime = _tests.putIfAbsent(
      testName,
      () => _AllureTestRuntime(
        uuid: _nextUuid(),
        testName: testName,
        fullName: testName,
      ),
    );
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
      _deferredSetUpAllAttachments.addAll(pendingSnapshots);
      return;
    }
    if (_isServiceTestName(testName)) return;

    final runtime = _ensureTestRuntime(testName);
    for (final pending in pendingSnapshots) {
      _attachSnapshotToRuntime(runtime, pending.name, pending.image);
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

  Future<void> _ensureActiveRunContext() async {
    final baseDirPath = await GetIt.I.get<FsService>().getBaseDataDirectory();
    final resultsDirPath =
        await GetIt.I.get<FsService>().getActiveSuperRunDataSubDirectory(
              category: 'AllureResults',
            );
    final reportDirPath =
        await GetIt.I.get<FsService>().getActiveSuperRunDataSubDirectory(
              category: 'AllureReport',
            );
    if (_resultsDirPath == resultsDirPath && _reportDirPath == reportDirPath) {
      return;
    }

    _resultsDirPath = resultsDirPath;
    _reportDirPath = reportDirPath;
    _historyCacheDirPath = '$baseDirPath/AllureHistoryCache/';
    _resetState();
  }

  Future<void> _clearAllureResults() async {
    final resultsDirPath = _resultsDirPath;
    final reportDirPath = _reportDirPath;
    if (resultsDirPath == null || reportDirPath == null) return;

    final resultsDir = Directory(resultsDirPath);
    if (resultsDir.existsSync()) {
      await resultsDir.delete(recursive: true);
    }
    await resultsDir.create(recursive: true);

    final reportDir = Directory(reportDirPath);
    if (reportDir.existsSync()) {
      await reportDir.delete(recursive: true);
    }
    await reportDir.create(recursive: true);

    _resetState();
  }

  Future<void> _hydrateHistoryIntoResults() async {
    final resultsDirPath = _resultsDirPath;
    final historyCacheDirPath = _historyCacheDirPath;
    if (resultsDirPath == null || historyCacheDirPath == null) return;

    final cacheDir = Directory(historyCacheDirPath);
    if (!cacheDir.existsSync()) return;

    final targetDir = Directory('${resultsDirPath}history/');
    if (targetDir.existsSync()) {
      await targetDir.delete(recursive: true);
    }
    await _copyDirectory(cacheDir, targetDir);
  }

  Future<void> _persistHistoryFromReportDir() async {
    final reportDirPath = _reportDirPath;
    final historyCacheDirPath = _historyCacheDirPath;
    if (reportDirPath == null || historyCacheDirPath == null) return;

    final reportHistoryDir = Directory('${reportDirPath}history/');
    if (!reportHistoryDir.existsSync()) return;

    final cacheDir = Directory(historyCacheDirPath);
    if (cacheDir.existsSync()) {
      await cacheDir.delete(recursive: true);
    }
    await _copyDirectory(reportHistoryDir, cacheDir);
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(recursive: true)) {
      final relativePath = entity.path.substring(source.path.length);
      final targetPath = '${target.path}$relativePath';
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
      } else if (entity is File) {
        final parentDir = Directory(targetPath).parent;
        if (!parentDir.existsSync()) {
          await parentDir.create(recursive: true);
        }
        await entity.copy(targetPath);
      }
    }
  }

  void _resetState() {
    _tests.clear();
    _testNameByLogEntryId.clear();
    _pendingSnapshotsByLogEntryId.clear();
    _deferredSetUpAllSteps.clear();
    _deferredSetUpAllAttachments.clear();
    _deferredSetUpAllLogBuffer = StringBuffer();
    _deferredSetUpAllInjected = false;
    _suiteInfo = null;
    _artifactCounter = 0;
    _uuidCounter = 0;
  }

  Future<bool> _startAllureOpenDetached(String reportDirPath) async {
    try {
      final process = await Process.start(
        'allure',
        ['open', reportDirPath],
        runInShell: true,
        mode: ProcessStartMode.detached,
      );
      Log.i(_kTag, 'allure open detached pid=${process.pid}');
      return true;
    } catch (e, s) {
      Log.e(_kTag, 'allure open failed e=$e s=$s');
      return false;
    }
  }

  final _random = Random();
  final _tests = <String, _AllureTestRuntime>{};
  final _testNameByLogEntryId = <int, String>{};
  final _pendingSnapshotsByLogEntryId = <int, List<_PendingSnapshot>>{};
  final _deferredSetUpAllSteps = <Map<String, dynamic>>[];
  final _deferredSetUpAllAttachments = <_PendingSnapshot>[];
  StringBuffer _deferredSetUpAllLogBuffer = StringBuffer();
  bool _deferredSetUpAllInjected = false;
  SuiteInfo? _suiteInfo;
  String? _resultsDirPath;
  String? _reportDirPath;
  String? _historyCacheDirPath;
  int _artifactCounter = 0;
  int _uuidCounter = 0;
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
  }) : historyId = testName;

  int get startMs => _startMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
  int get stopMs => _stopMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;

  void touchAt(int ms) {
    _startMs = _startMs == null ? ms : min(_startMs!, ms);
    _stopMs = _stopMs == null ? ms : max(_stopMs!, ms);
  }
}
