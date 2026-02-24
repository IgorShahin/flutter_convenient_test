import 'dart:io';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/services/fs_service.dart';
import 'package:convenient_test_manager_dart/services/screen_video_recorder_service.dart';
import 'package:convenient_test_manager_dart/stores/video_player_store.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';
import 'package:meta/meta.dart';
import 'package:mobx/mobx.dart';

part 'video_recorder_store.g.dart';

class VideoRecorderStore = _VideoRecorderStore with _$VideoRecorderStore;

abstract class _VideoRecorderStore with Store {
  static const _kTag = 'VideoRecorderStore';
  static const _kMinimumDurationToKeep = Duration(milliseconds: 300);
  static const _kMinimumSizeBytesToKeep = 4 * 1024;

  @observable
  VideoInfo? recordingVideoInfo;

  void clear() {
    recordingVideoInfo = null;
  }

  @action
  Future<void> startRecord() async {
    final path = await _createVideoPath();
    recordingVideoInfo = VideoInfo(
        path: path, startTime: DateTime.now(), endTime: _kInvalidTime);

    Log.d(_kTag, 'startRecord call ScreenVideoRecorderService begin');
    await GetIt.I.get<ScreenVideoRecorderService>().startRecord(path);
    Log.d(_kTag, 'startRecord call ScreenVideoRecorderService end');
  }

  @action
  Future<void> stopRecord() async {
    await stopRecordWithPolicy(keepVideo: true);
  }

  Future<void> stopRecordWithPolicy({required bool keepVideo}) async {
    final recorderService = GetIt.I.get<ScreenVideoRecorderService>();

    if (recordingVideoInfo == null) {
      Log.i(
        _kTag,
        'stopRecord has recordingVideoInfo==null, but still force-stop '
        'underlying recorder service to avoid dangling process',
      );
      await recorderService.stopRecord();
      return;
    }

    Log.d(_kTag, 'stopRecord call ScreenVideoRecorderService begin');
    await recorderService.stopRecord();
    Log.d(_kTag, 'stopRecord call ScreenVideoRecorderService end');

    final endTime = DateTime.now();
    final info = VideoInfo(
      path: recordingVideoInfo!.path,
      startTime: recordingVideoInfo!.startTime,
      // the [recordingVideoInfo!.endTime] is dummy value
      endTime: endTime,
    );

    final shouldKeep = keepVideo && await _shouldKeepVideo(info);
    if (shouldKeep) {
      GetIt.I.get<VideoPlayerStoreBase>().handleRecorderFinished(info);
    } else {
      Log.w(_kTag, 'stopRecord skip add video keepVideo=$keepVideo info=$info');
    }

    recordingVideoInfo = null;
  }

  Future<bool> _shouldKeepVideo(VideoInfo info) async {
    final duration = info.endTime.difference(info.startTime);
    if (duration < _kMinimumDurationToKeep) {
      Log.w(_kTag, 'video too short duration=$duration path=${info.path}');
      return false;
    }

    final file = File(info.path);
    if (!await file.exists()) {
      Log.w(_kTag, 'video file does not exist path=${info.path}');
      return false;
    }

    final sizeBytes = await file.length();
    if (sizeBytes < _kMinimumSizeBytesToKeep) {
      Log.w(
          _kTag, 'video file too small sizeBytes=$sizeBytes path=${info.path}');
      return false;
    }

    return true;
  }

  Future<String> _createVideoPath() async {
    final stem = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    return
        // ignore: prefer_interpolation_to_compose_strings
        await GetIt.I
                .get<FsService>()
                .getActiveSuperRunDataSubDirectory(category: 'Video') +
            '$stem.mov';
  }
}

final _kInvalidTime = DateTime.fromMicrosecondsSinceEpoch(-1);

@immutable
class VideoInfo {
  final String path;
  final DateTime startTime;
  final DateTime endTime;

  const VideoInfo({
    required this.path,
    required this.startTime,
    required this.endTime,
  });

  @override
  String toString() =>
      'VideoInfo{path: $path, startTime: $startTime, endTime: $endTime}';

  Duration absoluteToVideoTime(DateTime absoluteTime) =>
      absoluteTime.difference(startTime);

  DateTime videoToAbsoluteTime(Duration videoTime) => startTime.add(videoTime);
}
