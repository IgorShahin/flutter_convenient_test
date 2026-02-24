import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convenient_test_common/convenient_test_common.dart';
import 'package:convenient_test_dev/src/support/reporter_service.dart';
import 'package:fixnum/fixnum.dart';
import 'package:intl/intl.dart';

const kVideoChunkSnapshotPrefix = '__ct_video_chunk__';

class WorkerVideoRecordingService {
  static const _kTag = 'WorkerVideoRecordingService';
  static const _kChunkSizeBytes = 256 * 1024;
  static const _kMinimumDurationToKeep = Duration(milliseconds: 300);
  static const _kMinimumSizeBytesToKeep = 4 * 1024;

  // ignore: prefer_constructors_over_static_methods
  static WorkerVideoRecordingService create() {
    if (Platform.isMacOS) return _WorkerVideoRecordingServiceMacos();
    if (Platform.isWindows) return _WorkerVideoRecordingServiceWindows();
    if (Platform.isLinux) return _WorkerVideoRecordingServiceLinux();
    return WorkerVideoRecordingService();
  }

  Future<void> startRecord() async {
    Log.i(_kTag, 'startRecord no-op on this platform');
  }

  Future<void> stopAndUpload(WorkerReportSaverService reporterService) async {
    Log.i(_kTag, 'stopAndUpload no-op on this platform');
  }
}

abstract class _WorkerVideoRecordingServiceDesktopBase
    extends WorkerVideoRecordingService {
  Process? _process;
  DateTime? _startTime;
  String? _path;

  String get fileExtension;

  String get tag;

  Future<Process> startProcess(String targetPath);

  Future<void> stopProcess(Process process);

  @override
  Future<void> startRecord() async {
    try {
      if (_process != null) await _stopProcessSafely();

      final targetPath = await _createTargetPath();
      _startTime = DateTime.now();
      _path = targetPath;
      _process = await startProcess(targetPath);
    } catch (e, s) {
      Log.w(tag, 'startRecord failed; fallback to no-op e=$e s=$s');
      _process = null;
      _startTime = null;
      _path = null;
    }
  }

  @override
  Future<void> stopAndUpload(WorkerReportSaverService reporterService) async {
    final process = _process;
    final startTime = _startTime;
    final path = _path;

    _process = null;
    _startTime = null;
    _path = null;

    if (process == null || startTime == null || path == null) {
      Log.i(tag, 'stopAndUpload skip since process/start/path are null');
      return;
    }

    await _stopProcessSafely(process: process);

    final endTime = DateTime.now();
    final file = File(path);
    if (!await _shouldKeepVideo(file, startTime: startTime, endTime: endTime)) {
      return;
    }

    await _uploadInChunks(
      reporterService,
      file: file,
      startTime: startTime,
      endTime: endTime,
    );
    await _deleteFileQuietly(file);
  }

  Future<void> _stopProcessSafely({Process? process}) async {
    final target = process ?? _process;
    if (target == null) return;
    try {
      await stopProcess(target);
    } catch (e, s) {
      Log.w(tag, 'stopProcess failed e=$e s=$s');
    }
  }

  Future<bool> _shouldKeepVideo(
    File file, {
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    final duration = endTime.difference(startTime);
    if (duration < WorkerVideoRecordingService._kMinimumDurationToKeep) {
      Log.w(tag, 'video too short duration=$duration path=${file.path}');
      await _deleteFileQuietly(file);
      return false;
    }

    if (!await file.exists()) {
      Log.w(tag, 'video file does not exist path=${file.path}');
      return false;
    }

    final sizeBytes = await file.length();
    if (sizeBytes < WorkerVideoRecordingService._kMinimumSizeBytesToKeep) {
      Log.w(tag, 'video too small sizeBytes=$sizeBytes path=${file.path}');
      await _deleteFileQuietly(file);
      return false;
    }
    return true;
  }

  Future<void> _uploadInChunks(
    WorkerReportSaverService reporterService, {
    required File file,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    final sessionId = _createSessionId();
    final fileName = file.uri.pathSegments.last;
    final startMs = startTime.millisecondsSinceEpoch;
    final endMs = endTime.millisecondsSinceEpoch;

    final bytes = await file.readAsBytes();
    final totalChunks =
        (bytes.length / WorkerVideoRecordingService._kChunkSizeBytes).ceil();
    Log.i(
      tag,
      'uploadInChunks sessionId=$sessionId fileName=$fileName '
      'sizeBytes=${bytes.length} totalChunks=$totalChunks',
    );

    for (var i = 0; i < totalChunks; i++) {
      final start = i * WorkerVideoRecordingService._kChunkSizeBytes;
      final end = min(
        bytes.length,
        start + WorkerVideoRecordingService._kChunkSizeBytes,
      );
      final chunk = Uint8List.sublistView(bytes, start, end);
      final name =
          '$kVideoChunkSnapshotPrefix:$sessionId:$fileName:$startMs:$endMs:$i:${i == totalChunks - 1 ? 1 : 0}';

      await reporterService.report(
        ReportItem(
          snapshot: Snapshot(
            logEntryId: Int64.ZERO,
            name: name,
            image: chunk,
          ),
        ),
      );
    }
  }

  Future<void> _deleteFileQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<String> _createTargetPath() async {
    final stem = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final random = Random().nextInt(1000).toString().padLeft(3, '0');
    final dir = Directory('${Directory.systemTemp.path}/convenient_test_video');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return '${dir.path}/$stem-$random.$fileExtension';
  }

  String _createSessionId() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final pid = pidOrZero();
    final rand = Random().nextInt(1 << 20);
    return '$pid-$ts-$rand';
  }

  int pidOrZero() {
    try {
      return pid;
    } catch (_) {
      return 0;
    }
  }
}

class _WorkerVideoRecordingServiceMacos
    extends _WorkerVideoRecordingServiceDesktopBase {
  static const _kTag = 'WorkerVideoRecordingServiceMacos';
  static const _kStartupProbeTimeout = Duration(milliseconds: 700);

  @override
  String get tag => _kTag;

  @override
  String get fileExtension => 'mov';

  @override
  Future<Process> startProcess(String targetPath) async {
    final rect = _resolveMacosOwnWindowRect();
    if (rect != null) {
      final byWindow = await _startScreencapture(
        targetPath: targetPath,
        args: ['-x', '-v', '-R${rect.toArg()}', targetPath],
        modeLabel: 'window',
      );
      if (byWindow != null) {
        Log.i(_kTag, 'startRecord capture own app window rect=$rect');
        return byWindow;
      }
      Log.w(
        _kTag,
        'startRecord window mode failed, fallback to full display',
      );
    } else {
      Log.w(
        _kTag,
        'startRecord cannot resolve own app window; fallback to full display',
      );
    }

    final byDisplay = await _startScreencapture(
      targetPath: targetPath,
      args: ['-x', '-v', '-D', '1', targetPath],
      modeLabel: 'display',
    );
    if (byDisplay != null) {
      return byDisplay;
    }

    throw Exception(
      'Failed to start macOS screencapture. '
      'Please allow Screen Recording permission for the tested app/process.',
    );
  }

  Future<Process?> _startScreencapture({
    required String targetPath,
    required List<String> args,
    required String modeLabel,
  }) async {
    final process = await Process.start('screencapture', args);
    final stderrBuffer = StringBuffer();
    unawaited(
      process.stdout
          .transform(systemEncoding.decoder)
          .forEach((e) => Log.d(_kTag, '[STDOUT][$modeLabel] $e')),
    );
    unawaited(
      process.stderr.transform(systemEncoding.decoder).forEach((e) {
        stderrBuffer.write(e);
        Log.d(_kTag, '[STDERR][$modeLabel] $e');
      }),
    );

    final earlyExit = await Future.any<Object?>([
      process.exitCode.then<Object?>((code) => code),
      Future<void>.delayed(_kStartupProbeTimeout),
    ]);
    if (earlyExit is int) {
      final stderrText = stderrBuffer.toString().trim();
      Log.w(
        _kTag,
        'screencapture exited early mode=$modeLabel '
        'exitCode=$earlyExit targetPath=$targetPath stderr="$stderrText"',
      );
      return null;
    }

    return process;
  }

  @override
  Future<void> stopProcess(Process process) async {
    process.kill(ProcessSignal.sigint);
    final exitCode = await process.exitCode;
    Log.i(_kTag, 'stopRecord exitCode=$exitCode');
    if (exitCode != 0) {
      throw Exception('Process execution failed! exitCode=$exitCode');
    }
  }
}

class _WorkerVideoRecordingServiceWindows
    extends _WorkerVideoRecordingServiceDesktopBase {
  static const _kTag = 'WorkerVideoRecordingServiceWindows';

  @override
  String get tag => _kTag;

  @override
  String get fileExtension => 'mp4';

  @override
  Future<Process> startProcess(String targetPath) async {
    final hwnd = _resolveWindowsMainWindowHandleByCurrentPid();
    final input = hwnd == null ? 'desktop' : 'hwnd=$hwnd';
    if (hwnd == null) {
      Log.w(
        _kTag,
        'Cannot resolve own app window on Windows; fallback to desktop',
      );
    } else {
      Log.i(_kTag, 'Capture own app window by hwnd=$hwnd');
    }

    final process = await Process.start('ffmpeg', [
      '-y',
      '-loglevel',
      'error',
      '-f',
      'gdigrab',
      '-framerate',
      '8',
      '-i',
      input,
      '-vf',
      'scale=1280:-2',
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '35',
      '-pix_fmt',
      'yuv420p',
      '-movflags',
      '+faststart',
      targetPath,
    ]);
    unawaited(process.stdout
        .transform(systemEncoding.decoder)
        .forEach((e) => Log.d(_kTag, '[STDOUT] $e')));
    unawaited(process.stderr
        .transform(systemEncoding.decoder)
        .forEach((e) => Log.d(_kTag, '[STDERR] $e')));
    return process;
  }

  @override
  Future<void> stopProcess(Process process) async {
    try {
      process.stdin.writeln('q');
      await process.stdin.flush();
    } catch (_) {}
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    Log.i(_kTag, 'stopRecord exitCode=$exitCode');
    if (exitCode != 0) {
      throw Exception('Process execution failed! exitCode=$exitCode');
    }
  }
}

class _WorkerVideoRecordingServiceLinux
    extends _WorkerVideoRecordingServiceDesktopBase {
  static const _kTag = 'WorkerVideoRecordingServiceLinux';

  @override
  String get tag => _kTag;

  @override
  String get fileExtension => 'mp4';

  @override
  Future<Process> startProcess(String targetPath) async {
    final display = Platform.environment['DISPLAY'] ?? ':0';
    final windowId = _resolveLinuxWindowIdByCurrentPid();

    final args = <String>[
      '-y',
      '-loglevel',
      'error',
      '-f',
      'x11grab',
      '-framerate',
      '8',
      if (windowId != null) ...['-window_id', windowId],
      '-i',
      display,
      '-vf',
      'scale=1280:-2',
      '-c:v',
      'libx264',
      '-preset',
      'veryfast',
      '-crf',
      '35',
      '-pix_fmt',
      'yuv420p',
      '-movflags',
      '+faststart',
      targetPath,
    ];

    if (windowId == null) {
      Log.w(
          _kTag, 'Cannot resolve own app window on Linux; fallback to DISPLAY');
    } else {
      Log.i(_kTag, 'Capture own app window by X11 window_id=$windowId');
    }

    final process = await Process.start('ffmpeg', args);
    unawaited(process.stdout
        .transform(systemEncoding.decoder)
        .forEach((e) => Log.d(_kTag, '[STDOUT] $e')));
    unawaited(process.stderr
        .transform(systemEncoding.decoder)
        .forEach((e) => Log.d(_kTag, '[STDERR] $e')));
    return process;
  }

  @override
  Future<void> stopProcess(Process process) async {
    try {
      process.stdin.writeln('q');
      await process.stdin.flush();
    } catch (_) {}
    final exitCode = await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    Log.i(_kTag, 'stopRecord exitCode=$exitCode');
    if (exitCode != 0) {
      throw Exception('Process execution failed! exitCode=$exitCode');
    }
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

  String toArg() => '$x,$y,$width,$height';

  static _CaptureRect? tryParse(String raw) {
    if (raw.isEmpty) return null;
    final parts = raw.split(',');
    if (parts.length != 4) return null;

    final parsed = parts.map((e) => int.tryParse(e.trim())).toList();
    if (parsed.any((e) => e == null)) return null;

    final width = parsed[2]!;
    final height = parsed[3]!;
    if (width <= 0 || height <= 0) return null;

    return _CaptureRect(
      x: parsed[0]!,
      y: parsed[1]!,
      width: width,
      height: height,
    );
  }

  @override
  String toString() =>
      '_CaptureRect{x: $x, y: $y, width: $width, height: $height}';
}

_CaptureRect? _resolveMacosOwnWindowRect() {
  if (!Platform.isMacOS) return null;

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

  final result = Process.runSync(
    'osascript',
    ['-e', script, '$pid'],
  );
  if (result.exitCode != 0) return null;
  return _CaptureRect.tryParse((result.stdout as String).trim());
}

String? _resolveWindowsMainWindowHandleByCurrentPid() {
  if (!Platform.isWindows) return null;

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

String? _resolveLinuxWindowIdByCurrentPid() {
  if (!Platform.isLinux) return null;

  final result =
      Process.runSync('sh', ['-lc', 'xdotool search --pid $pid 2>/dev/null']);
  if (result.exitCode != 0) return null;

  final first = (result.stdout as String)
      .split('\n')
      .map((e) => e.trim())
      .firstWhere((e) => e.isNotEmpty, orElse: () => '');
  return first.isEmpty ? null : first;
}
