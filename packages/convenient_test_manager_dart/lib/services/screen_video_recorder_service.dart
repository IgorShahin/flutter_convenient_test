import 'dart:convert';
import 'dart:io';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/misc/runtime_platform.dart';

abstract class ScreenVideoRecorderService {
  static ScreenVideoRecorderService create() {
    if (!supportsIoPlatform) {
      return _ScreenVideoRecorderServiceIsolateExceptionDecorator(
        _ScreenVideoRecorderServiceNoOp(),
      );
    }

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

    final args = <String>[
      '-x',
      '-v',
    ];
    final rect = _resolveCaptureRect();
    if (rect != null) {
      args.add('-R${rect.toArg()}');
      Log.i(_kTag, 'startRecord will capture window region rect=$rect');
    } else {
      args
        ..add('-D')
        ..add('1');
      Log.w(
        _kTag,
        'startRecord cannot resolve app window region, fallback to full display recording',
      );
    }
    args.add(targetPath);

    final process = await Process.start('screencapture', args);
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

  _CaptureRect? _resolveCaptureRect() {
    final byTitle = _resolveCaptureRectByTitle();
    if (byTitle != null) return byTitle;
    final byWorkerPid = _resolveCaptureRectByWorkerVmServicePid();
    if (byWorkerPid != null) return byWorkerPid;
    return null;
  }

  _CaptureRect? _resolveCaptureRectByTitle() {
    final title = Platform.environment['CONVENIENT_TEST_RECORD_WINDOW_TITLE'];
    if (title == null || title.isEmpty) return null;

    const script = '''
on run argv
  set targetTitle to item 1 of argv
  tell application "System Events"
    repeat with p in application processes
      if background only of p is false then
        repeat with w in windows of p
          set winName to ""
          try
            set winName to name of w as text
          end try
          if winName contains targetTitle then
            set {xPos, yPos} to position of w
            set {wSize, hSize} to size of w
            return (xPos as text) & "," & (yPos as text) & "," & (wSize as text) & "," & (hSize as text)
          end if
        end repeat
      end if
    end repeat
  end tell
  return ""
end run
''';

    final result = Process.runSync('osascript', ['-e', script, title]);
    if (result.exitCode != 0) {
      Log.w(_kTag,
          'resolveCaptureRectByTitle failed title="$title" exitCode=${result.exitCode} stderr=${result.stderr}');
      return null;
    }
    final raw = (result.stdout as String).trim();
    final rect = _CaptureRect.tryParse(raw);
    if (rect == null) {
      Log.w(
          _kTag, 'resolveCaptureRectByTitle no window matched title="$title"');
    }
    return rect;
  }

  _CaptureRect? _resolveCaptureRectByWorkerVmServicePid() {
    final pid = _resolveListeningPidByPort(kWorkerVmServicePort);
    if (pid == null) return null;

    const script = '''
on run argv
  set targetPid to item 1 of argv as integer
  tell application "System Events"
    repeat with p in application processes
      try
        if unix id of p is targetPid then
          if (count of windows of p) is 0 then
            return ""
          end if
          set w to front window of p
          set {xPos, yPos} to position of w
          set {wSize, hSize} to size of w
          return (xPos as text) & "," & (yPos as text) & "," & (wSize as text) & "," & (hSize as text)
        end if
      end try
    end repeat
  end tell
  return ""
end run
''';

    final result = Process.runSync('osascript', ['-e', script, '$pid']);
    if (result.exitCode != 0) {
      Log.w(
        _kTag,
        'resolveCaptureRectByWorkerVmServicePid failed pid=$pid '
        'exitCode=${result.exitCode} stderr=${result.stderr}',
      );
      return null;
    }

    final raw = (result.stdout as String).trim();
    final rect = _CaptureRect.tryParse(raw);
    if (rect == null) {
      Log.w(
        _kTag,
        'resolveCaptureRectByWorkerVmServicePid no window for pid=$pid raw="$raw"',
      );
    } else {
      Log.i(
          _kTag, 'resolveCaptureRectByWorkerVmServicePid pid=$pid rect=$rect');
    }
    return rect;
  }
}

class _CaptureRect {
  final int x;
  final int y;
  final int width;
  final int height;

  const _CaptureRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  static _CaptureRect? tryParse(String raw) {
    if (raw.isEmpty) return null;
    final parts = raw.split(',');
    if (parts.length != 4) return null;

    final parsed = parts.map((e) => int.tryParse(e.trim())).toList();
    if (parsed.any((e) => e == null)) return null;
    final x = parsed[0]!;
    final y = parsed[1]!;
    final width = parsed[2]!;
    final height = parsed[3]!;
    if (width <= 0 || height <= 0) return null;

    return _CaptureRect(x: x, y: y, width: width, height: height);
  }

  String toArg() => '$x,$y,$width,$height';

  @override
  String toString() =>
      '_CaptureRect{x: $x, y: $y, width: $width, height: $height}';
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
  List<String> buildFfmpegArgs(String targetPath) {
    final windowTitle = _recordWindowTitle();
    final input = () {
      if (windowTitle != null) return 'title=$windowTitle';

      final hwnd = _resolveWindowsMainWindowHandleByWorkerVmServicePort();
      if (hwnd != null) return 'hwnd=$hwnd';

      return 'desktop';
    }();

    if (input.startsWith('title=')) {
      Log.i(
        _kTag,
        'Recording by window title on Windows: "$windowTitle" '
        '(ffmpeg input: $input)',
      );
    } else if (input.startsWith('hwnd=')) {
      Log.i(
        _kTag,
        'Recording by worker window handle on Windows '
        '(ffmpeg input: $input)',
      );
    } else {
      Log.w(
        _kTag,
        'Cannot auto-resolve worker app window on Windows. '
        'Fallback to desktop recording.',
      );
    }

    return [
      '-y',
      '-loglevel',
      'error',
      '-f',
      'gdigrab',
      '-framerate',
      _kCompressedFfmpegFramerate,
      '-i',
      input,
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

String? _recordWindowTitle() {
  final raw = Platform.environment['CONVENIENT_TEST_RECORD_WINDOW_TITLE'];
  if (raw == null) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _resolveWindowsMainWindowHandleByWorkerVmServicePort() {
  if (!Platform.isWindows) return null;

  final pid = _resolveWindowsListeningPid(kWorkerVmServicePort);
  if (pid == null) return null;

  const script = r'''
try {
  $p = Get-Process -Id $args[0] -ErrorAction Stop
  $h = $p.MainWindowHandle
  if ($h -eq 0) {
    ""
  } else {
    "0x{0:X}" -f $h
  }
} catch {
  ""
}
''';

  final result = Process.runSync(
    'powershell',
    ['-NoProfile', '-Command', script, '$pid'],
  );
  if (result.exitCode != 0) return null;

  final raw = (result.stdout as String).trim();
  if (raw.isEmpty) return null;

  return raw;
}

int? _resolveWindowsListeningPid(int port) {
  if (!Platform.isWindows) return null;

  final result = Process.runSync('cmd', ['/c', 'netstat -ano -p tcp']);
  if (result.exitCode != 0) return null;

  final lines = (result.stdout as String).split('\n');
  final regex = RegExp(r'^\s*TCP\s+(\S+)\s+(\S+)\s+LISTENING\s+(\d+)\s*$',
      caseSensitive: false);
  for (final line in lines) {
    final m = regex.firstMatch(line);
    if (m == null) continue;

    final localAddress = m.group(1) ?? '';
    if (!_matchesPortInAddress(localAddress, port)) continue;

    final pid = int.tryParse(m.group(3) ?? '');
    if (pid != null && pid > 0) return pid;
  }

  return null;
}

bool _matchesPortInAddress(String localAddress, int port) {
  // netstat can output forms like:
  // 127.0.0.1:9753, 0.0.0.0:9753, [::]:9753
  final suffix = ':$port';
  final normalized = localAddress.trim();
  return normalized.endsWith(suffix);
}

int? _resolveListeningPidByPort(int port) {
  final result = switch (Platform.operatingSystem) {
    'windows' => Process.runSync('cmd', ['/c', 'netstat -ano -p tcp']),
    'macos' => Process.runSync('lsof', ['-nP', '-iTCP:$port', '-sTCP:LISTEN']),
    _ => Process.runSync(
        'sh', ['-lc', 'ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null']),
  };
  if (result.exitCode != 0) return null;

  final stdout = result.stdout as String;
  if (Platform.isWindows) {
    final lines = stdout.split('\n');
    final regex = RegExp(
      r'^\s*TCP\s+(\S+)\s+(\S+)\s+LISTENING\s+(\d+)\s*$',
      caseSensitive: false,
    );
    for (final line in lines) {
      final m = regex.firstMatch(line);
      if (m == null) continue;
      final localAddress = m.group(1) ?? '';
      if (!_matchesPortInAddress(localAddress, port)) continue;
      final pid = int.tryParse(m.group(3) ?? '');
      if (pid != null && pid > 0) return pid;
    }
    return null;
  }

  if (Platform.isMacOS) {
    final lines = stdout.split('\n');
    for (var i = 1; i < lines.length; i++) {
      final cols = lines[i].trim().split(RegExp(r'\s+'));
      if (cols.length < 2) continue;
      final pid = int.tryParse(cols[1]);
      if (pid != null && pid > 0) return pid;
    }
    return null;
  }

  final linuxRegex = RegExp(r'pid=(\d+)');
  final m = linuxRegex.firstMatch(stdout);
  if (m == null) return null;
  final pid = int.tryParse(m.group(1) ?? '');
  return pid != null && pid > 0 ? pid : null;
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
