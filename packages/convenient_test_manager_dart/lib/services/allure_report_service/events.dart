part of '../allure_report_service.dart';

class _AllureEventProcessor {
  _AllureEventProcessor(this.owner);

  final ManagerAllureReportService owner;

  Future<void> handleItem(ReportItem item) async {
    final o = owner;
    switch (item.whichSubType()) {
      case ReportItem_SubType.suiteInfoProto:
        final suiteInfoDigest =
            crypto.sha1.convert(item.suiteInfoProto.writeToBuffer()).toString();
        final superRunId = GetIt.I
            .get<WorkerSuperRunStore>()
            .currSuperRunController
            .superRunId;
        final shouldReset =
            o._lastSuiteInfoDigestBySuperRunId[superRunId] != suiteInfoDigest;
        o._lastSuiteInfoDigestBySuperRunId[superRunId] = suiteInfoDigest;
        if (shouldReset) {
          o._resetRuntimeState();
        } else {
          Log.i(
            ManagerAllureReportService._kTag,
            'suiteInfo deduplicated for superRunId=$superRunId, skip allure reset',
          );
        }
        o._suiteInfo = SuiteInfo.fromProto(item.suiteInfoProto);
        return;
      case ReportItem_SubType.logEntry:
        handleLogEntry(item.logEntry);
        return;
      case ReportItem_SubType.runnerStateChange:
        await handleRunnerStateChange(item.runnerStateChange);
        return;
      case ReportItem_SubType.runnerError:
        handleRunnerError(item.runnerError);
        return;
      case ReportItem_SubType.runnerMessage:
        handleRunnerMessage(item.runnerMessage);
        return;
      case ReportItem_SubType.snapshot:
        await handleSnapshot(item.snapshot);
        return;
      case ReportItem_SubType.setUpAll:
        return;
      case ReportItem_SubType.tearDownAll:
        await handleTearDownAll();
        return;
      case ReportItem_SubType.notSet:
        return;
    }
  }

  Future<void> handleTearDownAll() async {
    await owner._backfillVideosForFinishedTests();
  }

  void handleLogEntry(LogEntry request) {
    final o = owner;
    final logEntryId = request.id.toInt();
    o._testNameByLogEntryId[logEntryId] = request.testName;
    if (o._isSetUpAllServiceTestName(request.testName)) {
      if (o._isPureHttpLogEntry(request)) {
        for (final sub in request.subEntries) {
          final subMs = _usToMs(sub.time.toInt());
          o._deferredSetUpAllLogBuffer.writeln(o._formatRawLogLine(sub, subMs));
        }
        o._drainPendingSnapshots(logEntryId, request.testName);
        return;
      }
      o._runtimeUuidByLogEntryId.remove(logEntryId);
      o._deferredSetUpAllLastStepIndexByLogEntryId.remove(logEntryId);
      for (final sub in request.subEntries) {
        final subMs = _usToMs(sub.time.toInt());
        if (o._isTextAttachmentMarker(sub)) {
          o._handleDeferredTextAttachment(logEntryId: logEntryId, sub: sub);
          continue;
        }
        final prevIndex =
            o._deferredSetUpAllLastStepIndexByLogEntryId[logEntryId];
        if (prevIndex != null &&
            prevIndex >= 0 &&
            prevIndex < o._deferredSetUpAllSteps.length) {
          final prevStep = o._deferredSetUpAllSteps[prevIndex];
          final prevStart = (prevStep['start'] as int?) ?? subMs;
          prevStep['stop'] = max(prevStart, subMs);
        }
        final step = o._buildStep(sub, subMs);
        final stepIndex = o._deferredSetUpAllSteps.length;
        o._deferredSetUpAllSteps.add(step);
        o._deferredSetUpAllLastStepIndexByLogEntryId[logEntryId] = stepIndex;
        o._deferredSetUpAllLogBuffer.writeln(o._formatRawLogLine(sub, subMs));
      }
      o._drainPendingSnapshots(logEntryId, request.testName);
      return;
    }
    if (o._isServiceTestName(request.testName)) return;

    final runtime = o._runtimeForIncomingEvent(request.testName);
    final wasFinished = runtime.finished;
    o._runtimeUuidByLogEntryId[logEntryId] = runtime.uuid;
    o._lastStepPointerByLogEntryId.remove(logEntryId);

    if (o._isPureHttpLogEntry(request)) {
      for (final sub in request.subEntries) {
        final subMs = _usToMs(sub.time.toInt());
        runtime.touchAt(subMs);
        runtime.logBuffer.writeln(o._formatRawLogLine(sub, subMs));
      }
      o._attachHttpLogEntryToPendingCheck(runtime: runtime, request: request);
      o._drainPendingSnapshots(logEntryId, request.testName);
      return;
    }

    var hasHttpCheckMarker = false;

    for (final sub in request.subEntries) {
      final subMs = _usToMs(sub.time.toInt());
      runtime.touchAt(subMs);

      final prevPointer = o._lastOpenStepPointerByRuntimeUuid[runtime.uuid];
      if (prevPointer != null) {
        o._closeStepPointer(
            runtime: runtime, pointer: prevPointer, stopMs: subMs);
      }

      if (o._isTextAttachmentMarker(sub)) {
        o._attachTextAttachmentToCurrentContext(
          runtime: runtime,
          logEntryId: logEntryId,
          sub: sub,
        );
        continue;
      }

      if (_shouldSkipErrorLikeSubEntry(runtime, sub)) {
        runtime.logBuffer.writeln(o._formatRawLogLine(sub, subMs));
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
        runtime.logBuffer.writeln(o._formatRawLogLine(sub, subMs));
        continue;
      }

      final step = o._buildStep(sub, subMs);
      final routing = o._hookRoutingFromLogSubEntry(runtime: runtime, sub: sub);
      final pointer = o._appendStepByRouting(
        runtime: runtime,
        routing: routing,
        step: step,
      );
      o._lastStepPointerByLogEntryId[logEntryId] = pointer;
      o._lastOpenStepPointerByRuntimeUuid[runtime.uuid] = pointer;
      if (errorSignature != null) {
        runtime.errorSignatures.add(errorSignature);
      }
      runtime.logBuffer.writeln(o._formatRawLogLine(sub, subMs));
      if (o._isHttpCheckMarker(sub)) {
        runtime.pendingHttpCheckPointer = pointer;
        hasHttpCheckMarker = true;
      }
    }

    if (!hasHttpCheckMarker) {
      runtime.pendingHttpCheckPointer = null;
    }

    o._drainPendingSnapshots(logEntryId, request.testName);
    if (wasFinished) {
      o._rewriteFinalizedRuntime(runtime);
    }
  }

  Future<void> handleRunnerStateChange(RunnerStateChange request) async {
    final o = owner;
    if (o._isServiceTestName(request.testName)) return;

    final runtime = o._ensureActiveRuntime(request.testName);

    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    runtime.touchAt(nowMs);
    runtime.status = _mergeRuntimeStatus(
      current: runtime.status,
      incoming: _allureStatusFromResult(request.state.result),
    );

    if (request.state.status == 'complete') {
      await o._finalize(runtime);
    }
  }

  void handleRunnerError(RunnerError request) {
    final o = owner;
    if (o._isSetUpAllServiceTestName(request.testName)) {
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      o._deferredSetUpAllSteps.add(
        o._buildExceptionStep(
          error: request.error,
          stackTrace: request.stackTrace,
          atMs: nowMs,
          status: 'broken',
        ),
      );
      o._deferredSetUpAllLogBuffer.writeln('RUNNER ERROR: ${request.error}');
      if (request.stackTrace.isNotEmpty) {
        o._deferredSetUpAllLogBuffer.writeln(request.stackTrace);
      }
      return;
    }
    if (o._isServiceTestName(request.testName)) return;

    final runtime = o._runtimeForIncomingEvent(request.testName);
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
        o._rewriteFinalizedRuntime(runtime);
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
        o._rewriteFinalizedRuntime(runtime);
      }
      return;
    }

    runtime.statusDetails = {
      'message': request.error,
      'trace': request.stackTrace,
    };
    final prevPointer =
        o._lastOpenStepPointerByRuntimeUuid.remove(runtime.uuid);
    if (prevPointer != null) {
      o._closeStepPointer(
          runtime: runtime, pointer: prevPointer, stopMs: nowMs);
    }
    runtime.steps.add(
      o._buildExceptionStep(
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
      o._rewriteFinalizedRuntime(runtime);
    }
  }

  void handleRunnerMessage(RunnerMessage request) {
    final o = owner;
    final customTags = o._parseAllureTagsMarker(request.message);
    if (customTags != null) {
      if (o._isSetUpAllServiceTestName(request.testName) ||
          o._isServiceTestName(request.testName)) {
        return;
      }
      final runtime = o._runtimeForIncomingEvent(request.testName);
      runtime.customTags.addAll(customTags);
      if (runtime.finished) {
        o._rewriteFinalizedRuntime(runtime);
      }
      return;
    }
    final stepStart = o._parseRunnerMessageJsonMarker(
      request.message,
      ManagerAllureReportService._kAllureStepStartPrefix,
    );
    if (stepStart != null) {
      if (o._isSetUpAllServiceTestName(request.testName) ||
          o._isServiceTestName(request.testName)) {
        return;
      }
      final runtime = o._runtimeForIncomingEvent(request.testName);
      final wasFinished = runtime.finished;
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      runtime.touchAt(nowMs);
      o._handleAllureCustomStepStart(
          runtime: runtime, payload: stepStart, atMs: nowMs);
      if (wasFinished) {
        o._rewriteFinalizedRuntime(runtime);
      }
      return;
    }
    final stepEnd = o._parseRunnerMessageJsonMarker(
      request.message,
      ManagerAllureReportService._kAllureStepEndPrefix,
    );
    if (stepEnd != null) {
      if (o._isSetUpAllServiceTestName(request.testName) ||
          o._isServiceTestName(request.testName)) {
        return;
      }
      final runtime = o._runtimeForIncomingEvent(request.testName);
      final wasFinished = runtime.finished;
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      runtime.touchAt(nowMs);
      o._handleAllureCustomStepEnd(
          runtime: runtime, payload: stepEnd, atMs: nowMs);
      if (wasFinished) {
        o._rewriteFinalizedRuntime(runtime);
      }
      return;
    }
    final stepParameter = o._parseRunnerMessageJsonMarker(
      request.message,
      ManagerAllureReportService._kAllureStepParameterPrefix,
    );
    if (stepParameter != null) {
      if (o._isSetUpAllServiceTestName(request.testName) ||
          o._isServiceTestName(request.testName)) {
        return;
      }
      final runtime = o._runtimeForIncomingEvent(request.testName);
      final wasFinished = runtime.finished;
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      runtime.touchAt(nowMs);
      o._handleAllureCustomStepParameter(
          runtime: runtime, payload: stepParameter);
      if (wasFinished) {
        o._rewriteFinalizedRuntime(runtime);
      }
      return;
    }
    final stepTextAttachment = o._parseRunnerMessageJsonMarker(
      request.message,
      ManagerAllureReportService._kAllureStepTextAttachmentPrefix,
    );
    if (stepTextAttachment != null) {
      if (o._isSetUpAllServiceTestName(request.testName) ||
          o._isServiceTestName(request.testName)) {
        return;
      }
      final runtime = o._runtimeForIncomingEvent(request.testName);
      final wasFinished = runtime.finished;
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      runtime.touchAt(nowMs);
      o._handleAllureCustomStepAttachment(
        runtime: runtime,
        payload: stepTextAttachment,
        type: 'text/plain',
        extension: 'txt',
      );
      if (wasFinished) {
        o._rewriteFinalizedRuntime(runtime);
      }
      return;
    }
    final stepJsonAttachment = o._parseRunnerMessageJsonMarker(
      request.message,
      ManagerAllureReportService._kAllureStepJsonAttachmentPrefix,
    );
    if (stepJsonAttachment != null) {
      if (o._isSetUpAllServiceTestName(request.testName) ||
          o._isServiceTestName(request.testName)) {
        return;
      }
      final runtime = o._runtimeForIncomingEvent(request.testName);
      final wasFinished = runtime.finished;
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      runtime.touchAt(nowMs);
      o._handleAllureCustomStepAttachment(
        runtime: runtime,
        payload: stepJsonAttachment,
        type: 'application/json',
        extension: 'json',
      );
      if (wasFinished) {
        o._rewriteFinalizedRuntime(runtime);
      }
      return;
    }
    if (o._isSetUpAllServiceTestName(request.testName)) {
      o._deferredSetUpAllLogBuffer
          .writeln('RUNNER MESSAGE: ${request.message}');
      return;
    }
    if (o._isServiceTestName(request.testName)) return;

    final runtime = o._runtimeForIncomingEvent(request.testName);
    final wasFinished = runtime.finished;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    runtime.touchAt(nowMs);
    runtime.logBuffer.writeln('RUNNER MESSAGE: ${request.message}');
    if (wasFinished) {
      o._rewriteFinalizedRuntime(runtime);
    }
  }

  Future<void> handleSnapshot(Snapshot request) async {
    final o = owner;
    if (request.name.startsWith(
        '${ManagerAllureReportService._kVideoChunkSnapshotPrefix}:')) {
      return;
    }

    final logEntryId = request.logEntryId.toInt();
    final testName = o._testNameByLogEntryId[logEntryId];
    if (testName == null) {
      (o._pendingSnapshotsByLogEntryId[logEntryId] ??= []).add(
        _PendingSnapshot(name: request.name, image: request.image as Uint8List),
      );
      return;
    }
    if (o._isSetUpAllServiceTestName(testName)) {
      final deferredStepIndex =
          o._deferredSetUpAllLastStepIndexByLogEntryId[logEntryId];
      if (deferredStepIndex == null) {
        o._deferredSetUpAllAttachments.add(
          _PendingSnapshot(
              name: request.name, image: request.image as Uint8List),
        );
      } else {
        attachSnapshotToStep(
          steps: o._deferredSetUpAllSteps,
          stepIndex: deferredStepIndex,
          snapshotName: 'setUpAll:${request.name}',
          bytes: request.image as Uint8List,
        );
      }
      return;
    }
    if (o._isServiceTestName(testName)) return;

    final runtime = o._runtimeByLogEntryId(logEntryId) ??
        o._activeRuntimeByTestName[testName] ??
        o._ensureActiveRuntime(testName);
    final stepPointer = o._lastStepPointerByLogEntryId[logEntryId];
    if (stepPointer == null || runtime.finished) {
      attachSnapshotToRuntime(
          runtime, request.name, request.image as Uint8List);
    } else {
      final steps = o._stepsForPointer(runtime, stepPointer);
      if (steps == null) {
        attachSnapshotToRuntime(
            runtime, request.name, request.image as Uint8List);
        return;
      }
      attachSnapshotToStep(
        steps: steps,
        stepIndex: stepPointer.index,
        snapshotName: request.name,
        bytes: request.image as Uint8List,
      );
    }
  }

  void attachSnapshotToRuntime(
    _AllureTestRuntime runtime,
    String snapshotName,
    Uint8List bytes,
  ) {
    final o = owner;
    if (o._resultsDirPath == null) return;
    final extension = _detectImageExtension(bytes);
    final source = o._nextArtifactName('attachment', extension);
    final path = '${o._resultsDirPath}$source';
    File(path).writeAsBytesSync(bytes, flush: true);

    runtime.attachments.add({
      'name': snapshotName.isEmpty ? 'snapshot' : snapshotName,
      'source': source,
      'type': _mimeTypeForExtension(extension),
    });
  }

  void attachSnapshotToFixture({
    required _AllureFixtureRuntime fixture,
    required String snapshotName,
    required Uint8List bytes,
  }) {
    final o = owner;
    if (o._resultsDirPath == null) return;
    final extension = _detectImageExtension(bytes);
    final source = o._nextArtifactName('attachment', extension);
    final path = '${o._resultsDirPath}$source';
    File(path).writeAsBytesSync(bytes, flush: true);

    fixture.attachments.add({
      'name': snapshotName.isEmpty ? 'snapshot' : snapshotName,
      'source': source,
      'type': _mimeTypeForExtension(extension),
    });
  }

  void attachSnapshotToStep({
    required List<Map<String, dynamic>> steps,
    required int stepIndex,
    required String snapshotName,
    required Uint8List bytes,
  }) {
    final o = owner;
    if (stepIndex < 0 || stepIndex >= steps.length) return;
    if (o._resultsDirPath == null) return;

    final extension = _detectImageExtension(bytes);
    final source = o._nextArtifactName('attachment', extension);
    final path = '${o._resultsDirPath}$source';
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
}
