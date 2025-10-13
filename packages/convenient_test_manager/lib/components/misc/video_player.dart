import 'dart:async';

import 'package:convenient_test_common/convenient_test_common.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class VideoPlayerController with AttachableStateMixin<_VideoPlayerState> {
  final _positionController = StreamController<Duration>.broadcast();
  Stream<Duration> get positionStream => _positionController.stream;

  // публичные действия
  Future<void> seek(Duration pos) async => _seekDelegate?.call(pos);
  Future<void> play() async => _playDelegate?.call();
  Future<void> pause() async => _pauseDelegate?.call();

  // emit текущей позиции наружу (слушает store)
  void _emitPosition(Duration pos) {
    if (!_positionController.isClosed) {
      _positionController.add(pos);
    }
  }

  void dispose() {
    _positionController.close();
  }

  // делегаты, которые выставляет State
  Future<void> Function(Duration pos)? _seekDelegate;
  Future<void> Function()? _playDelegate;
  Future<void> Function()? _pauseDelegate;
}

class VideoPlayer extends StatefulWidget {
  final String videoPath;
  final Duration startTime;
  final Duration stopTime;
  final VideoPlayerController controller;

  const VideoPlayer({
    super.key,
    required this.videoPath,
    required this.startTime,
    required this.stopTime,
    required this.controller,
  });

  @override
  State<VideoPlayer> createState() => _VideoPlayerState();
}

class _VideoPlayerState extends State<VideoPlayer> {
  late final Player _player;
  late final VideoController _videoController;
  StreamSubscription<Duration>? _posSub;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);

    // прокинуть делегаты в контроллер
    widget.controller._seekDelegate = (d) => _player.seek(d);
    widget.controller._playDelegate  = () => _player.play();
    widget.controller._pauseDelegate = () => _player.pause();

    _openAndSeek();

    // позиция → наружу + авто-стоп на stopTime
    _posSub = _player.stream.position.listen((pos) async {
      widget.controller._emitPosition(pos);
      if (pos >= widget.stopTime) {
        await _player.pause();
      }
    });
  }

  Future<void> _openAndSeek() async {
    await _player.open(Media(widget.videoPath), play: false);
    if (widget.startTime > Duration.zero) {
      await _player.seek(widget.startTime);
    }
    await _player.play();
  }

  @override
  void didUpdateWidget(covariant VideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoPath != widget.videoPath) {
      _player.stop();
      _openAndSeek();
      return;
    }
    if (oldWidget.startTime != widget.startTime ||
        oldWidget.stopTime != widget.stopTime) {
      () async {
        await _player.pause();
        await _player.seek(widget.startTime);
        await _player.play();
      }();
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ВАЖНО: именно здесь attach/detach State к контроллеру
    return AttachableStateAttacherWidget<VideoPlayerController, _VideoPlayerState>(
      target: widget.controller,
      state: this,
      child: Video(controller: _videoController),
    );
  }
}
