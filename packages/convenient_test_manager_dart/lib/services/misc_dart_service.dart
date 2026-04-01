import 'dart:io';
import 'dart:typed_data';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/services/report_handler_service.dart';
import 'package:convenient_test_manager_dart/services/vm_service_wrapper_service.dart';
import 'package:convenient_test_manager_dart/stores/allure_custom_step_store.dart';
import 'package:convenient_test_manager_dart/stores/log_store.dart';
import 'package:convenient_test_manager_dart/stores/raw_log_store.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:get_it/get_it.dart';
import 'package:protobuf/protobuf.dart';

class MiscDartService {
  static const _kTag = 'MiscDartService';

  void hotRestartAndRunTests({required String filterNameRegex}) {
    Log.d(_kTag, 'hotRestartAndRunTests filterNameRegex=$filterNameRegex');
    GetIt.I
        .get<WorkerSuperRunStore>()
        .setControllerIntegrationTest(filterNameRegex: filterNameRegex);
    GetIt.I.get<VmServiceWrapperService>().hotRestartThrottled();
  }

  void hotRestartAndRunInAppMode() {
    Log.d(_kTag, 'hotRestartAndRunInAppMode');
    GetIt.I.get<WorkerSuperRunStore>().setControllerInteractiveApp();
    GetIt.I.get<VmServiceWrapperService>().hotRestartThrottled();
  }

  void reloadInfo() {
    GetIt.I.get<WorkerSuperRunStore>().setControllerIntegrationTest(
        filterNameRegex: RegexUtils.kMatchNothing);
    GetIt.I.get<VmServiceWrapperService>().hotRestartThrottled();
  }

  void haltWorker() {
    GetIt.I.get<WorkerSuperRunStore>().setControllerHalt();
    GetIt.I.get<VmServiceWrapperService>().hotRestartThrottled();
  }

  void clearAll() {
    Log.d(_kTag, 'clearAll');

    GetIt.I.get<SuiteInfoStore>().clear();
    GetIt.I.get<AllureCustomStepStore>().clear();
    GetIt.I.get<LogStore>().clear();
    GetIt.I.get<RawLogStore>().clear();
    // Do not clear VideoRecorderStore here.
    // `SuiteInfoProto` can arrive asynchronously after `SetUpAll`, and clearing
    // recorder state would lose `recordingVideoInfo` for the active run.
  }

  Future<void> readReportFromFile(String path,
      {bool sync = false, bool doClear = true}) async {
    Log.d(_kTag, 'readReportFromFile start path=$path');

    final fileBytes =
        sync ? File(path).readAsBytesSync() : await File(path).readAsBytes();
    await readReportFromBytes(fileBytes, doClear: doClear);
  }

  Future<void> readReportFromBytes(
    Uint8List fileBytes, {
    bool doClear = true,
  }) async {
    Log.d(_kTag, 'readReportFromBytes start size=${fileBytes.length}');

    clearAll();
    final reader = CodedBufferReader(fileBytes,
        sizeLimit: 1073741824); // allow for up to 1 Gigabyte

    final reportCollection = ReportCollection.create();
    reportCollection.mergeFromCodedBufferReader(reader);
    Log.i(
      _kTag,
      'readReportFromBytes parsed items=${reportCollection.items.length}',
    );
    if (reportCollection.items.isEmpty) {
      Log.w(
        _kTag,
        'readReportFromBytes parsed zero items. '
        'Likely selected file is not a convenient_test report protobuf',
      );
    }

    Log.d(_kTag, 'readReportFromBytes handle reportCollection');
    await GetIt.I
        .get<ReportHandlerService>()
        .handle(reportCollection, offlineFile: true, doClear: doClear);

    Log.d(_kTag, 'readReportFromBytes end');
  }
}
