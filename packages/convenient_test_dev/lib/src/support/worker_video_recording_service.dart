import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convenient_test_common/convenient_test_common.dart';
import 'package:convenient_test_dev/src/support/reporter_service.dart';
import 'package:crypto/crypto.dart';
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

  Future<void> forceStopDanglingProcesses() async {
    Log.i(_kTag, 'forceStopDanglingProcesses no-op on this platform');
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

  Future<File> postProcessRecordedFile(File file) async => file;

  Future<void> cleanupBeforeStart() async {}

  @override
  Future<void> startRecord() async {
    try {
      await cleanupBeforeStart();
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
    var file = File(path);
    file = await postProcessRecordedFile(file);
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
    final encodedFileName = Uri.encodeComponent(fileName);
    final startMs = startTime.millisecondsSinceEpoch;
    final endMs = endTime.millisecondsSinceEpoch;

    final bytes = await file.readAsBytes();
    final fileSha256 = sha256.convert(bytes).toString();
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
          '$kVideoChunkSnapshotPrefix:$sessionId:$encodedFileName:$startMs:$endMs:$i:${i == totalChunks - 1 ? 1 : 0}:$totalChunks:$fileSha256';

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
  _MacosRecorderBackend _backend = _MacosRecorderBackend.none;

  @override
  String get tag => _kTag;

  @override
  String get fileExtension => 'mov';

  @override
  Future<void> cleanupBeforeStart() async {
    await forceStopDanglingProcesses();
  }

  @override
  Future<void> forceStopDanglingProcesses() async {
    await _killOrphanRecorderProcesses(
        processName: 'screencapture', marker: 'convenient_test_video');
    await _killOrphanRecorderProcesses(
        processName: 'ffmpeg', marker: 'convenient_test_video');
  }

  @override
  Future<File> postProcessRecordedFile(File file) async {
    // Normalize to a stable MP4 stream to avoid partial playback/freezes.
    final ffmpegVersion = Process.runSync('ffmpeg', ['-version']);
    if (ffmpegVersion.exitCode != 0) {
      Log.w(_kTag, 'ffmpeg not available, skip post-process for ${file.path}');
      return file;
    }

    final outputPath =
        file.path.replaceFirst(RegExp(r'\.[^.]+$'), '.normalized.mp4');
    final output = File(outputPath);
    if (await output.exists()) {
      await output.delete();
    }

    final result = await Process.run(
      'ffmpeg',
      [
        '-y',
        '-loglevel',
        'error',
        '-i',
        file.path,
        '-an',
        '-vf',
        'scale=1280:-2,fps=8',
        '-vsync',
        'cfr',
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
        output.path,
      ],
    );

    if (result.exitCode != 0 || !await output.exists()) {
      Log.w(
        _kTag,
        'post-process failed exitCode=${result.exitCode} '
        'stderr="${(result.stderr as String).trim()}"',
      );
      return file;
    }

    try {
      await file.delete();
    } catch (_) {}

    Log.i(
        _kTag, 'post-process success input=${file.path} output=${output.path}');
    return output;
  }

  @override
  Future<Process> startProcess(String targetPath) async {
    final rawRect = _resolveMacosOwnWindowRect();
    final rect = rawRect == null ? null : _cropTopPanelFromRect(rawRect);
    if (rect != null) {
      final byWindow = await _startScreencapture(
        targetPath: targetPath,
        args: ['-x', '-v', '-R${rect.toArg()}', targetPath],
        modeLabel: 'window',
      );
      if (byWindow != null) {
        Log.i(
          _kTag,
          'startRecord capture own app window rect=$rect rawRect=$rawRect',
        );
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
      _backend = _MacosRecorderBackend.screencapture;
      return byDisplay;
    }

    final byFfmpeg = await _startFfmpegAvfoundation(targetPath: targetPath);
    if (byFfmpeg != null) {
      _backend = _MacosRecorderBackend.ffmpegAvfoundation;
      return byFfmpeg;
    }

    _backend = _MacosRecorderBackend.none;
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

    _backend = _MacosRecorderBackend.screencapture;
    return process;
  }

  Future<Process?> _startFfmpegAvfoundation(
      {required String targetPath}) async {
    final ffmpegVersion = Process.runSync('ffmpeg', ['-version']);
    if (ffmpegVersion.exitCode != 0) {
      Log.w(
        _kTag,
        'ffmpeg is not available on worker. skip avfoundation fallback.',
      );
      return null;
    }

    for (final videoIndex in const [1, 0, 2]) {
      final args = [
        '-y',
        '-loglevel',
        'error',
        '-f',
        'avfoundation',
        '-framerate',
        '8',
        '-i',
        '$videoIndex:none',
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

      final process = await Process.start('ffmpeg', args);
      final stderrBuffer = StringBuffer();
      unawaited(
        process.stdout
            .transform(systemEncoding.decoder)
            .forEach((e) => Log.d(_kTag, '[STDOUT][ffmpeg-avf] $e')),
      );
      unawaited(
        process.stderr.transform(systemEncoding.decoder).forEach((e) {
          stderrBuffer.write(e);
          Log.d(_kTag, '[STDERR][ffmpeg-avf] $e');
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
          'ffmpeg avfoundation exited early videoIndex=$videoIndex '
          'exitCode=$earlyExit stderr="$stderrText"',
        );
        continue;
      }

      Log.i(
        _kTag,
        'startRecord fallback to ffmpeg avfoundation with videoIndex=$videoIndex',
      );
      return process;
    }

    return null;
  }

  @override
  Future<void> stopProcess(Process process) async {
    final exitCode = switch (_backend) {
      _MacosRecorderBackend.screencapture => await _stopBySigint(process),
      _MacosRecorderBackend.ffmpegAvfoundation => await _stopFfmpeg(process),
      _MacosRecorderBackend.none => await process.exitCode,
    };

    _backend = _MacosRecorderBackend.none;
    Log.i(_kTag, 'stopRecord exitCode=$exitCode');
    if (exitCode != 0) {
      throw Exception('Process execution failed! exitCode=$exitCode');
    }
  }

  Future<int> _stopBySigint(Process process) async {
    process.kill(ProcessSignal.sigint);
    return process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigterm);
        return process.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            process.kill();
            return -1;
          },
        );
      },
    );
  }

  Future<int> _stopFfmpeg(Process process) async {
    try {
      process.stdin.writeln('q');
      await process.stdin.flush();
    } catch (_) {}

    return process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
  }

  Future<void> _killOrphanRecorderProcesses({
    required String processName,
    required String marker,
  }) async {
    final pgrep = await Process.run('pgrep', ['-f', processName]);
    if (pgrep.exitCode != 0) return;

    final pidLines = (pgrep.stdout as String)
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);

    for (final pidText in pidLines) {
      final targetPid = int.tryParse(pidText);
      if (targetPid == null || targetPid <= 0 || targetPid == pid) continue;

      final ps =
          await Process.run('ps', ['-p', '$targetPid', '-o', 'command=']);
      if (ps.exitCode != 0) continue;
      final command = (ps.stdout as String).trim();
      if (!command.contains(marker)) continue;

      Log.w(
        _kTag,
        'cleanupBeforeStart terminate orphan recorder '
        'processName=$processName pid=$targetPid command="$command"',
      );

      Process.killPid(targetPid, ProcessSignal.sigint);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      Process.killPid(targetPid, ProcessSignal.sigterm);
    }
  }
}

enum _MacosRecorderBackend {
  none,
  screencapture,
  ffmpegAvfoundation,
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
    final captureRect = _resolveWindowsContentRectByCurrentPid();
    final hwnd = _resolveWindowsMainWindowHandleByCurrentPid();

    late final List<String> inputArgs;
    if (captureRect != null) {
      inputArgs = [
        '-offset_x',
        '${captureRect.x}',
        '-offset_y',
        '${captureRect.y}',
        '-video_size',
        '${captureRect.width}x${captureRect.height}',
        '-i',
        'desktop',
      ];
      Log.i(_kTag, 'Capture own app content area on Windows rect=$captureRect');
    } else if (hwnd != null) {
      inputArgs = ['-i', 'hwnd=$hwnd'];
      Log.i(_kTag, 'Capture own app window by hwnd=$hwnd');
    } else {
      inputArgs = ['-i', 'desktop'];
      Log.w(
        _kTag,
        'Cannot resolve own app content/window on Windows; fallback to desktop',
      );
    }

    final process = await Process.start('ffmpeg', [
      '-y',
      '-loglevel',
      'error',
      '-f',
      'gdigrab',
      '-framerate',
      '8',
      ...inputArgs,
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
    final contentRect = windowId == null
        ? null
        : _resolveLinuxContentRectByWindowId(windowId);

    final args = <String>[
      '-y',
      '-loglevel',
      'error',
      '-f',
      'x11grab',
      '-framerate',
      '8',
      if (contentRect != null) ...[
        '-video_size',
        '${contentRect.width}x${contentRect.height}',
        '-i',
        '$display+${contentRect.x},${contentRect.y}',
      ] else if (windowId != null) ...[
        '-window_id',
        windowId,
        '-i',
        display,
      ] else ...[
        '-i',
        display,
      ],
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

    if (contentRect != null) {
      Log.i(_kTag, 'Capture own app content area on Linux rect=$contentRect');
    } else if (windowId != null) {
      Log.i(_kTag, 'Capture own app window by X11 window_id=$windowId');
    } else {
      Log.w(
          _kTag, 'Cannot resolve own app window on Linux; fallback to DISPLAY');
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

_CaptureRect _cropTopPanelFromRect(_CaptureRect rawRect) {
  const kDefaultTopInsetPx = 28;

  final parsedInset = (() {
    final raw = Platform.environment['CONVENIENT_TEST_RECORD_TOP_INSET_PX'];
    return raw == null ? null : int.tryParse(raw);
  })();
  final topInsetPx =
      parsedInset == null ? kDefaultTopInsetPx : max(0, min(parsedInset, 5000));

  final maxInset = max(0, rawRect.height - 100);
  final safeInset = min(topInsetPx, maxInset);
  if (safeInset <= 0) return rawRect;

  return _CaptureRect(
    x: rawRect.x,
    y: rawRect.y + safeInset,
    width: rawRect.width,
    height: rawRect.height - safeInset,
  );
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

_CaptureRect? _resolveWindowsContentRectByCurrentPid() {
  if (!Platform.isWindows) return null;

  const script = r'''
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class User32 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
}
"@
try {
  $p = Get-Process -Id $args[0] -ErrorAction Stop
  $h = $p.MainWindowHandle
  if ($h -eq 0) { "" ; exit 0 }
  $rect = New-Object User32+RECT
  if (-not [User32]::GetClientRect([intptr]$h, [ref]$rect)) { "" ; exit 0 }
  $pt = New-Object User32+POINT
  $pt.X = 0; $pt.Y = 0
  if (-not [User32]::ClientToScreen([intptr]$h, [ref]$pt)) { "" ; exit 0 }
  $w = $rect.Right - $rect.Left
  $hgt = $rect.Bottom - $rect.Top
  if ($w -le 0 -or $hgt -le 0) { "" ; exit 0 }
  "$($pt.X),$($pt.Y),$w,$hgt"
} catch {
  ""
}
''';

  final result = Process.runSync(
    'powershell',
    ['-NoProfile', '-Command', script, '$pid'],
  );
  if (result.exitCode != 0) return null;

  return _CaptureRect.tryParse((result.stdout as String).trim());
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

_CaptureRect? _resolveLinuxContentRectByWindowId(String windowId) {
  if (!Platform.isLinux) return null;

  final xwin = Process.runSync('xwininfo', ['-id', windowId]);
  if (xwin.exitCode != 0) return null;

  final text = xwin.stdout as String;
  final absX = _parseLabeledInt(text, 'Absolute upper-left X');
  final absY = _parseLabeledInt(text, 'Absolute upper-left Y');
  final width = _parseLabeledInt(text, 'Width');
  final height = _parseLabeledInt(text, 'Height');
  if (absX == null || absY == null || width == null || height == null) {
    return null;
  }
  if (width <= 0 || height <= 0) return null;

  // Prefer NET frame extents when window manager provides them.
  final extents = _resolveLinuxFrameExtents(windowId);
  if (extents != null) {
    final x = absX + extents.left;
    final y = absY + extents.top;
    final w = width - extents.left - extents.right;
    final h = height - extents.top - extents.bottom;
    if (w > 0 && h > 0) {
      return _CaptureRect(x: x, y: y, width: w, height: h);
    }
  }

  // Fallback heuristic: xwininfo often reports client offset as "Relative ...".
  final relX = _parseLabeledInt(text, 'Relative upper-left X') ?? 0;
  final relY = _parseLabeledInt(text, 'Relative upper-left Y') ?? 0;
  final safeRelX = relX < 0 ? 0 : relX;
  final safeRelY = relY < 0 ? 0 : relY;
  final x = absX + safeRelX;
  final y = absY + safeRelY;
  final w = width - safeRelX;
  final h = height - safeRelY;
  if (w <= 0 || h <= 0) return _CaptureRect(x: absX, y: absY, width: width, height: height);

  return _CaptureRect(x: x, y: y, width: w, height: h);
}

_LinuxFrameExtents? _resolveLinuxFrameExtents(String windowId) {
  final result = Process.runSync(
    'xprop',
    ['-id', windowId, '_NET_FRAME_EXTENTS'],
  );
  if (result.exitCode != 0) return null;

  final text = (result.stdout as String).trim();
  final match = RegExp(r'=\s*(-?\d+),\s*(-?\d+),\s*(-?\d+),\s*(-?\d+)')
      .firstMatch(text);
  if (match == null) return null;

  final left = int.tryParse(match.group(1)!);
  final right = int.tryParse(match.group(2)!);
  final top = int.tryParse(match.group(3)!);
  final bottom = int.tryParse(match.group(4)!);
  if (left == null || right == null || top == null || bottom == null) {
    return null;
  }

  return _LinuxFrameExtents(
    left: left < 0 ? 0 : left,
    right: right < 0 ? 0 : right,
    top: top < 0 ? 0 : top,
    bottom: bottom < 0 ? 0 : bottom,
  );
}

int? _parseLabeledInt(String text, String label) {
  final match = RegExp('$label:\\s*(-?\\d+)', multiLine: true).firstMatch(text);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

class _LinuxFrameExtents {
  final int left;
  final int right;
  final int top;
  final int bottom;

  const _LinuxFrameExtents({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
  });
}
