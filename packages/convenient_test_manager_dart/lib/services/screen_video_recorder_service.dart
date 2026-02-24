import 'dart:io';
import 'dart:convert';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';

abstract class ScreenVideoRecorderService {
  static ScreenVideoRecorderService create() {
    final inner = _ScreenVideoRecorderServiceIosSimulator.maybeCreate() ??
        _ScreenVideoRecorderServiceMacosDesktop.maybeCreate() ??
        _ScreenVideoRecorderServiceWindowsDesktop.maybeCreate() ??
        _ScreenVideoRecorderServiceLinuxDesktop.maybeCreate() ??
        _ScreenVideoRecorderServiceNoOp();
    return _ScreenVideoRecorderServiceIsolateExceptionDecorator(inner);
  }

  Future<void> startRecord(String targetPath);

  Future<void> stopRecord();
}

const _kCompressedFfmpegFramerate = '8';
const _kCompressedFfmpegScaleFilter = 'scale=1280:-2';
const _kCompressedFfmpegPreset = 'veryfast';
const _kCompressedFfmpegCrf = '35';

class _ScreenVideoRecorderServiceIsolateExceptionDecorator
    implements ScreenVideoRecorderService {
  static const _kTag = 'ScreenVideoRecorderServiceIsolateExceptionDecorator';

  final ScreenVideoRecorderService inner;

  _ScreenVideoRecorderServiceIsolateExceptionDecorator(this.inner);

  @override
  Future<void> startRecord(String targetPath) =>
      _captureException(() => inner.startRecord(targetPath));

  @override
  Future<void> stopRecord() => _captureException(inner.stopRecord);

  Future<void> _captureException(Future<void> Function() body) async {
    try {
      await body();
    } catch (e, s) {
      Log.w(_kTag, 'capture and ignore exception e=$e s=$s');
    }
  }
}

class _ScreenVideoRecorderServiceIosSimulator
    extends ScreenVideoRecorderService {
  static const _kTag = 'ScreenVideoRecorderServiceIosSimulator';

  static _ScreenVideoRecorderServiceIosSimulator? maybeCreate() {
    // non-mac computers cannot have ios simulators
    if (!Platform.isMacOS) return null;
    if (!_hasBootedIosSimulator()) return null;

    return _ScreenVideoRecorderServiceIosSimulator();
  }

  static bool _hasBootedIosSimulator() {
    final result = Process.runSync(
      'xcrun',
      ['simctl', 'list', 'devices', 'booted', 'iOS', '--json'],
    );
    if (result.exitCode != 0) return false;

    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! Map<String, dynamic>) return false;
    final devices = decoded['devices'];
    if (devices is! Map<String, dynamic>) return false;
    final flatValues = devices.values.whereType<List<dynamic>>();
    return flatValues.any((list) => list.isNotEmpty);
  }

  Process? _process;

  @override
  Future<void> startRecord(String targetPath) async {
    Log.i(_kTag, 'startRecord begin $targetPath');

    if (_process != null) await stopRecord();

    final process = await Process.start(
        'xcrun', ['simctl', 'io', 'booted', 'recordVideo', targetPath]);
    _process = process;

    process.stdout
        .listen((e) => Log.d(_kTag, '[STDOUT] ${String.fromCharCodes(e)}'));
    process.stderr
        .listen((e) => Log.d(_kTag, '[STDERR] ${String.fromCharCodes(e)}'));
  }

  @override
  Future<void> stopRecord() async {
    Log.i(_kTag, 'stopRecord begin');

    final process = _process;
    _process = null;
    if (process == null) {
      Log.w(_kTag, 'stopRecord skip since process==null');
      return;
    }

    Log.i(_kTag, 'stopRecord send signals');
    process.kill(ProcessSignal.sigint); // simulate Ctrl+C
    // process.kill(ProcessSignal.sigterm);

    Log.i(_kTag, 'stopRecord await exitCode');
    final exitCode = await process.exitCode;

    Log.i(_kTag, 'stopRecord exitCode=$exitCode');
    if (exitCode != 0) {
      throw Exception('Process execution failed! exitCode=$exitCode');
    }
  }
}

class _ScreenVideoRecorderServiceMacosDesktop
    extends ScreenVideoRecorderService {
  static const _kTag = 'ScreenVideoRecorderServiceMacosDesktop';

  static _ScreenVideoRecorderServiceMacosDesktop? maybeCreate() {
    if (!Platform.isMacOS) return null;
    return _ScreenVideoRecorderServiceMacosDesktop();
  }

  Process? _process;

  @override
  Future<void> startRecord(String targetPath) async {
    Log.i(_kTag, 'startRecord begin $targetPath');

    if (_process != null) await stopRecord();

    final process = await Process.start('screencapture', [
      '-x',
      '-v',
      '-D',
      '1',
      targetPath,
    ]);
    _process = process;

    process.stdout
        .listen((e) => Log.d(_kTag, '[STDOUT] ${String.fromCharCodes(e)}'));
    process.stderr
        .listen((e) => Log.d(_kTag, '[STDERR] ${String.fromCharCodes(e)}'));
  }

  @override
  Future<void> stopRecord() async {
    Log.i(_kTag, 'stopRecord begin');

    final process = _process;
    _process = null;
    if (process == null) {
      Log.w(_kTag, 'stopRecord skip since process==null');
      return;
    }

    Log.i(_kTag, 'stopRecord send signals');
    process.kill(ProcessSignal.sigint); // simulate Ctrl+C

    Log.i(_kTag, 'stopRecord await exitCode');
    final exitCode = await process.exitCode;

    Log.i(_kTag, 'stopRecord exitCode=$exitCode');
    if (exitCode != 0) {
      throw Exception('Process execution failed! exitCode=$exitCode');
    }
  }
}

class _ScreenVideoRecorderServiceWindowsDesktop
    extends _ScreenVideoRecorderServiceFfmpegBase {
  static const _kTag = 'ScreenVideoRecorderServiceWindowsDesktop';

  _ScreenVideoRecorderServiceWindowsDesktop._();

  static _ScreenVideoRecorderServiceWindowsDesktop? maybeCreate() {
    if (!Platform.isWindows) return null;
    if (!_isFfmpegAvailable()) {
      Log.w(_kTag, 'ffmpeg is not available, fallback to no-op recorder');
      return null;
    }
    return _ScreenVideoRecorderServiceWindowsDesktop._();
  }

  @override
  String get tag => _kTag;

  @override
  List<String> buildFfmpegArgs(String targetPath) => [
        '-y',
        '-loglevel',
        'error',
        '-f',
        'gdigrab',
        '-framerate',
        _kCompressedFfmpegFramerate,
        '-i',
        'desktop',
        '-vf',
        _kCompressedFfmpegScaleFilter,
        '-c:v',
        'libx264',
        '-preset',
        _kCompressedFfmpegPreset,
        '-crf',
        _kCompressedFfmpegCrf,
        '-pix_fmt',
        'yuv420p',
        '-movflags',
        '+faststart',
        targetPath,
      ];
}

class _ScreenVideoRecorderServiceLinuxDesktop
    extends _ScreenVideoRecorderServiceFfmpegBase {
  static const _kTag = 'ScreenVideoRecorderServiceLinuxDesktop';

  final String display;

  _ScreenVideoRecorderServiceLinuxDesktop._({required this.display});

  static _ScreenVideoRecorderServiceLinuxDesktop? maybeCreate() {
    if (!Platform.isLinux) return null;
    if (!_isFfmpegAvailable()) {
      Log.w(_kTag, 'ffmpeg is not available, fallback to no-op recorder');
      return null;
    }

    final display = Platform.environment['DISPLAY'];
    if (display == null || display.isEmpty) {
      Log.w(
        _kTag,
        'DISPLAY is not available. Linux recorder currently supports X11 only.',
      );
      return null;
    }

    return _ScreenVideoRecorderServiceLinuxDesktop._(display: display);
  }

  @override
  String get tag => _kTag;

  @override
  List<String> buildFfmpegArgs(String targetPath) => [
        '-y',
        '-loglevel',
        'error',
        '-f',
        'x11grab',
        '-framerate',
        _kCompressedFfmpegFramerate,
        '-i',
        display,
        '-vf',
        _kCompressedFfmpegScaleFilter,
        '-c:v',
        'libx264',
        '-preset',
        _kCompressedFfmpegPreset,
        '-crf',
        _kCompressedFfmpegCrf,
        '-pix_fmt',
        'yuv420p',
        '-movflags',
        '+faststart',
        targetPath,
      ];
}

abstract class _ScreenVideoRecorderServiceFfmpegBase
    extends ScreenVideoRecorderService {
  Process? _process;

  String get tag;

  List<String> buildFfmpegArgs(String targetPath);

  @override
  Future<void> startRecord(String targetPath) async {
    Log.i(tag, 'startRecord begin $targetPath');

    if (_process != null) await stopRecord();

    final process = await Process.start('ffmpeg', buildFfmpegArgs(targetPath));
    _process = process;

    process.stdout
        .listen((e) => Log.d(tag, '[STDOUT] ${String.fromCharCodes(e)}'));
    process.stderr
        .listen((e) => Log.d(tag, '[STDERR] ${String.fromCharCodes(e)}'));
  }

  @override
  Future<void> stopRecord() async {
    Log.i(tag, 'stopRecord begin');

    final process = _process;
    _process = null;
    if (process == null) {
      Log.w(tag, 'stopRecord skip since process==null');
      return;
    }

    try {
      process.stdin.writeln('q');
      await process.stdin.flush();
    } catch (e, s) {
      Log.w(tag, 'stopRecord failed to send "q" command e=$e s=$s');
    }

    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );

    Log.i(tag, 'stopRecord exitCode=$exitCode');
    if (exitCode != 0) {
      throw Exception('Process execution failed! exitCode=$exitCode');
    }
  }
}

bool _isFfmpegAvailable() {
  try {
    final result = Process.runSync('ffmpeg', ['-version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

class _ScreenVideoRecorderServiceNoOp extends ScreenVideoRecorderService {
  static const _kTag = 'ScreenVideoRecorderServiceNoOp';

  @override
  Future<void> startRecord(String targetPath) async {
    Log.i(_kTag, 'startRecord but do nothing');
  }

  @override
  Future<void> stopRecord() async {
    Log.i(_kTag, 'stopRecord but do nothing');
  }
}
