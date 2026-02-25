import 'dart:io';

import 'package:convenient_test_manager_dart/stores/global_config_store.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:get_it/get_it.dart';

abstract class FsService {
  Future<String> getBaseDataDirectory() async =>
      GlobalConfigStore.config.reportSavePath ??
      '${await getTemporaryDirectory()}/ConvenientTest';

  Future<String> getActiveSuperRunDataDirectory() async {
    final superRunId =
        GetIt.I.get<WorkerSuperRunStore>().currSuperRunController.superRunId;
    final ans = '${await getBaseDataDirectory()}/$superRunId/';
    Directory(ans).createSync(recursive: true);
    return ans;
  }

  Future<String> getActiveSuperRunDataSubDirectory(
      {required String category}) async {
    final ans = '${await getActiveSuperRunDataDirectory()}$category/';
    Directory(ans).createSync(recursive: true);
    return ans;
  }

  Future<void> clearActiveSuperRunDataDirectory() async {
    final path = await getActiveSuperRunDataDirectory();
    final dir = Directory(path);
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  Future<String> getTemporaryDirectory();
}

class FsServiceDart extends FsService {
  @override
  Future<String> getTemporaryDirectory() async => '/tmp';
}
