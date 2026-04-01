part of '../allure_report_service.dart';

class _AllurePersistence {
  _AllurePersistence(this.owner);

  final ManagerAllureReportService owner;

  Future<void> finalize(_AllureTestRuntime runtime) async {
    final o = owner;
    if (o._resultsDirPath == null || runtime.finished) return;
    runtime.finished = true;
    _closeOpenAllureCustomSteps(runtime);

    final openPointer =
        o._lastOpenStepPointerByRuntimeUuid.remove(runtime.uuid);
    if (openPointer != null) {
      o._closeStepPointer(
        runtime: runtime,
        pointer: openPointer,
        stopMs: runtime.stopMs,
      );
    }

    await o._attachRecordedVideosToRuntime(runtime);

    if (runtime.logBuffer.isNotEmpty) {
      final source = o._nextArtifactName('attachment', 'txt');
      final path = '${o._resultsDirPath}$source';
      File(path).writeAsStringSync(runtime.logBuffer.toString(), flush: true);
      runtime.attachments.add({
        'name': 'raw-log',
        'source': source,
        'type': 'text/plain',
      });
    }

    final suiteGroupNames = o._suiteGroupNamesForTest(runtime.testName);
    _decorateSetupFixtureByGroups(
      runtime: runtime,
      suiteGroupNames: suiteGroupNames,
    );
    final displayName = o._displayNameForTest(runtime.testName);

    final labels = <Map<String, String>>[
      {'name': 'framework', 'value': 'convenient_test'},
      {'name': 'language', 'value': 'dart'},
      {'name': 'host', 'value': Platform.localHostname},
    ];
    labels.addAll(o._suiteLabelsForTest(runtime.testName));
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

    await removePreviousResultForHistoryId(runtime.historyId);

    final resultFileName = '${runtime.uuid}-result.json';
    final resultPath = '${o._resultsDirPath}$resultFileName';
    File(resultPath).writeAsStringSync(jsonEncode(result), flush: true);
    runtime.resultPath = resultPath;
    await writeContainer(runtime);

    final active = o._activeRuntimeByTestName[runtime.testName];
    if (identical(active, runtime)) {
      o._activeRuntimeByTestName.remove(runtime.testName);
    }
  }

  Future<void> ensureActiveRunContext() async {
    final o = owner;
    final resultsDirPath =
        await GetIt.I.get<FsService>().getActiveSuperRunDataSubDirectory(
              category: 'AllureResults',
            );
    if (o._resultsDirPath == resultsDirPath) {
      return;
    }

    o._resultsDirPath = resultsDirPath;
    resetState();
  }

  Future<void> clearAllureResults() async {
    final o = owner;
    final resultsDirPath = o._resultsDirPath;
    if (resultsDirPath == null) return;

    final resultsDir = Directory(resultsDirPath);
    if (resultsDir.existsSync()) {
      await resultsDir.delete(recursive: true);
    }
    await resultsDir.create(recursive: true);

    resetState();
  }

  Future<void> clearLocalAllureArtifacts({bool clearResults = false}) async {
    await ensureActiveRunContext();
    await clearAllureResults();

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
        ManagerAllureReportService._kTag,
        'local allure history cleared (results and report reset together)',
      );
    }
  }

  Future<void> removePreviousResultForHistoryId(String historyId) async {
    final o = owner;
    final resultsDirPath = o._resultsDirPath;
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

  Future<void> writeContainer(_AllureTestRuntime runtime) async {
    final o = owner;
    if (o._resultsDirPath == null) return;
    final befores = runtime.beforeFixtures.values
        .where((e) => e.hasRenderableContent)
        .map((e) => e.toJson())
        .toList();
    final afters = runtime.afterFixtures.values
        .where((e) => e.hasRenderableContent)
        .map((e) => e.toJson())
        .toList();
    if (befores.isEmpty && afters.isEmpty) return;

    final containerUuid = o._nextUuid();
    final container = <String, dynamic>{
      'uuid': containerUuid,
      'name': runtime.fullName,
      'children': [runtime.uuid],
      'befores': befores,
      'afters': afters,
      'start': runtime.startMs,
      'stop': runtime.stopMs,
    };
    final containerPath = '${o._resultsDirPath}$containerUuid-container.json';
    File(containerPath).writeAsStringSync(jsonEncode(container), flush: true);
  }

  void rewriteFinalizedRuntime(_AllureTestRuntime runtime) {
    final o = owner;
    final resultPath = runtime.resultPath;
    if (o._resultsDirPath == null || resultPath == null || resultPath.isEmpty) {
      return;
    }

    rewriteRawLogAttachment(runtime);
    final suiteGroupNames = o._suiteGroupNamesForTest(runtime.testName);
    _decorateSetupFixtureByGroups(
      runtime: runtime,
      suiteGroupNames: suiteGroupNames,
    );
    final displayName = o._displayNameForTest(runtime.testName);

    final labels = <Map<String, String>>[
      {'name': 'framework', 'value': 'convenient_test'},
      {'name': 'language', 'value': 'dart'},
      {'name': 'host', 'value': Platform.localHostname},
    ];
    labels.addAll(o._suiteLabelsForTest(runtime.testName));
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

  void rewriteRawLogAttachment(_AllureTestRuntime runtime) {
    final o = owner;
    if (o._resultsDirPath == null || runtime.logBuffer.isEmpty) return;

    Map<String, dynamic>? rawLogAttachment;
    for (final attachment in runtime.attachments) {
      if (attachment['name'] == 'raw-log' &&
          attachment['type'] == 'text/plain') {
        rawLogAttachment = attachment;
        break;
      }
    }

    if (rawLogAttachment == null) {
      final source = o._nextArtifactName('attachment', 'txt');
      runtime.attachments.add({
        'name': 'raw-log',
        'source': source,
        'type': 'text/plain',
      });
      rawLogAttachment = runtime.attachments.last;
    }

    final source = rawLogAttachment['source'] as String?;
    if (source == null || source.trim().isEmpty) return;
    final path = '${o._resultsDirPath}$source';
    File(path).writeAsStringSync(runtime.logBuffer.toString(), flush: true);
  }

  void resetState() {
    final o = owner;
    o._activeRuntimeByTestName.clear();
    o._attemptCountByTestName.clear();
    o._latestRuntimeByTestName.clear();
    o._runtimeByUuid.clear();
    o._testNameByLogEntryId.clear();
    o._runtimeUuidByLogEntryId.clear();
    o._lastStepPointerByLogEntryId.clear();
    o._lastOpenStepPointerByRuntimeUuid.clear();
    o._pendingSnapshotsByLogEntryId.clear();
    o._deferredSetUpAllSteps.clear();
    o._deferredSetUpAllLastStepIndexByLogEntryId.clear();
    o._deferredSetUpAllAttachments.clear();
    o._deferredSetUpAllTextAttachments.clear();
    o._deferredSetUpAllLogBuffer = StringBuffer();
    o._deferredSetUpAllInjected = false;
    o._suiteInfo = null;
    o._consumedVideoAttachmentPaths.clear();
    o._artifactCounter = 0;
    o._uuidCounter = 0;
  }

  void resetRuntimeState() {
    resetState();
  }

  Future<bool> openUrlDetached(String url) async {
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
      Log.e(ManagerAllureReportService._kTag,
          'open url failed e=$e s=$s url=$url');
      return false;
    }
  }
}
