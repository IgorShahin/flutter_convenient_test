import 'dart:async';

import 'package:convenient_test_common/convenient_test_common.dart';
import 'package:flutter/material.dart';

class VideoPlayerController with AttachableStateMixin<_VideoPlayerState> {
  final _positionController = StreamController<Duration>.broadcast();
  Stream<Duration> get positionStream => _positionController.stream;

  Future<void> seek(Duration pos) async => _seekDelegate?.call(pos);
  Future<void> play() async => _playDelegate?.call();
  Future<void> pause() async => _pauseDelegate?.call();

  void _emitPosition(Duration pos) {
    if (!_positionController.isClosed) {
      _positionController.add(pos);
    }
  }

  void dispose() {
    _positionController.close();
  }

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
  @override
  void initState() {
    super.initState();
    widget.controller._seekDelegate =
        (pos) async => widget.controller._emitPosition(pos);
    widget.controller._playDelegate = () async {};
    widget.controller._pauseDelegate = () async {};
    widget.controller._emitPosition(widget.startTime);
  }

  @override
  Widget build(BuildContext context) {
    return AttachableStateAttacherWidget<VideoPlayerController,
        _VideoPlayerState>(
      target: widget.controller,
      state: this,
      child: const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Video playback is temporarily disabled in Test Manager.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
