import 'dart:async';
import 'dart:typed_data';

import 'package:convenient_test_common/convenient_test_common.dart';
import 'package:convenient_test_manager/stores/highlight_store.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager/stores/video_player_store.dart';
import 'package:convenient_test_manager_dart/misc/runtime_platform.dart';
import 'package:convenient_test_manager_dart/services/allure_report_service.dart';
import 'package:convenient_test_manager_dart/services/misc_dart_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:get_it/get_it.dart';
import 'package:mobx/mobx.dart';

class MiscFlutterService extends MiscDartService {
  static const _kTag = 'MiscFlutterService';
  static const _kOpenAllurePublishTimeout = Duration(seconds: 20);

  @override
  void reloadInfo() {
    GetIt.I.get<HighlightStore>().enableAutoExpand = true;
    super.reloadInfo();
  }

  @override
  void clearAll() {
    super.clearAll();
    GetIt.I.get<HighlightStore>().clear();
    GetIt.I.get<VideoPlayerStore>().clear();
  }

  Future<void> pickFileAndReadReport(
      {String? pathOverride, bool readSync = false, bool clear = true}) async {
    const effectiveClear = false;
    String? path;
    Uint8List? bytes;
    if (pathOverride == null) {
      final result = await FilePicker.platform.pickFiles(
          allowMultiple: false, withData: true, withReadStream: true);
      if (result == null) return;

      final file = result.files.single;
      if (supportsIoPlatform) {
        path = file.path;
      } else {
        path = null;
      }
      bytes = file.bytes;
      Log.i(
        _kTag,
        'pickFileAndReadReport selected '
        'name=${file.name} size=${file.size} path=$path '
        'hasBytes=${bytes != null} hasReadStream=${file.readStream != null}',
      );

      if (bytes == null && file.readStream != null) {
        bytes = await _collectBytes(file.readStream!);
        Log.i(
          _kTag,
          'pickFileAndReadReport collected bytes from stream size=${bytes.length}',
        );
      }
    } else {
      path = pathOverride;
      Log.i(_kTag, 'pickFileAndReadReport pathOverride=$path');
    }

    try {
      if (path != null && supportsIoPlatform) {
        Log.i(_kTag, 'pickFileAndReadReport load from file path');
        await readReportFromFile(
          path,
          sync: readSync,
          doClear: effectiveClear,
        );
      } else if (bytes != null) {
        Log.i(_kTag, 'pickFileAndReadReport load from in-memory bytes');
        await readReportFromBytes(bytes, doClear: effectiveClear);
      } else {
        throw Exception(
          'Cannot read report file: no filesystem path and no in-memory bytes from file picker',
        );
      }

      GetIt.I.get<HomePageStore>().displayLoadedReportMode = true;
      Log.i(_kTag, 'pickFileAndReadReport success');
    } catch (e, s) {
      GetIt.I.get<HomePageStore>().displayLoadedReportMode = false;
      Log.e(_kTag, 'pickFileAndReadReport failed e=$e s=$s');
      rethrow;
    }
  }

  Future<Uint8List> _collectBytes(Stream<List<int>> stream) async {
    final chunks = <int>[];
    await for (final chunk in stream) {
      chunks.addAll(chunk);
    }
    return Uint8List.fromList(chunks);
  }

  Future<void> openAllureReportSite() async {
    final homePageStore = GetIt.I.get<HomePageStore>();
    final allureService = GetIt.I.get<ManagerAllureReportService>();
    runInAction(() {
      homePageStore.allurePublishUiState.value =
          AllurePublishUiState.publishing;
    });
    try {
      await allureService
          .autoPublishToDockerIfConfigured(force: true)
          .timeout(_kOpenAllurePublishTimeout);
      runInAction(() {
        homePageStore.allurePublishUiState.value =
            AllurePublishUiState.published;
      });
    } on TimeoutException catch (e, s) {
      runInAction(() {
        homePageStore.allurePublishUiState.value =
            AllurePublishUiState.timeout;
      });
      Log.w(_kTag, 'openAllureReportSite publish timeout e=$e s=$s');
    } catch (e, s) {
      runInAction(() {
        homePageStore.allurePublishUiState.value = AllurePublishUiState.failed;
      });
      Log.w(_kTag, 'openAllureReportSite publish failed e=$e s=$s');
    } finally {
      await allureService.openLatestReportSite();
    }
  }
}
