import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:convenient_test_common/convenient_test_common.dart';
import 'package:convenient_test_dev/src/support/reporter_service.dart';
import 'package:crypto/crypto.dart';
import 'package:fixnum/fixnum.dart';
import 'package:intl/intl.dart';
import 'package:recaster/recaster.dart';

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

abstract class _WorkerVideoRecordingServiceRecasterBase
    extends WorkerVideoRecordingService {
  static const _kStartTimeout = Duration(seconds: 10);
  static const _kStopTimeout = Duration(seconds: 15);
  static const _kIsRecordingTimeout = Duration(seconds: 2);
  final Recaster _recaster = Recaster();
  DateTime? _startTime;
  String? _targetPath;

  String get tag;
  String get fileExtension;
  int get fps => 8;
  int get resolutionDivisor => 1;

  @override
  Future<void> startRecord() async {
    final sw = Stopwatch()..start();
    try {
      Log.i(tag, 'recaster.start begin');
      await forceStopDanglingProcesses();
      final targetPath = await _createTargetPath();
      await _recaster.startRecording(
        outputPath: targetPath,
        fps: fps,
        resolutionDivisor: resolutionDivisor,
      ).timeout(_kStartTimeout);
      _startTime = DateTime.now();
      _targetPath = targetPath;
      Log.i(
        tag,
        'recaster.start success targetPath=$targetPath elapsedMs=${sw.elapsedMilliseconds}',
      );
    } on TimeoutException catch (e, s) {
      Log.w(tag, 'recaster.start timeout e=$e s=$s');
      _startTime = null;
      _targetPath = null;
    } catch (e, s) {
      Log.w(tag, 'recaster.start failed e=${_shortError(e)} s=$s');
      _startTime = null;
      _targetPath = null;
    }
  }

  @override
  Future<void> forceStopDanglingProcesses() async {
    final isRecording = await _recaster.isRecording().timeout(
          _kIsRecordingTimeout,
          onTimeout: () => false,
        );
    if (isRecording != true) return;

    try {
      Log.w(tag, 'recaster.forceStop begin');
      final stoppedPath = await _recaster.stopRecording().timeout(_kStopTimeout);
      final file = File((stoppedPath ?? '').trim());
      if (await file.exists()) {
        await file.delete();
      }
      Log.w(tag, 'recaster.forceStop success stoppedPath=$stoppedPath');
    } on TimeoutException catch (e, s) {
      Log.w(tag, 'recaster.forceStop timeout e=$e s=$s');
    } catch (e, s) {
      Log.w(tag, 'recaster.forceStop failed e=${_shortError(e)} s=$s');
    }
  }

  @override
  Future<void> stopAndUpload(WorkerReportSaverService reporterService) async {
    final startTime = _startTime;
    final targetPath = _targetPath;
    _startTime = null;
    _targetPath = null;

    if (startTime == null || targetPath == null) {
      Log.i(tag, 'stopAndUpload skip since start/path are null');
      return;
    }

    final sw = Stopwatch()..start();
    final endTime = DateTime.now();
    try {
      Log.i(tag, 'recaster.stop begin targetPath=$targetPath');
      final savedPath = await _recaster.stopRecording().timeout(_kStopTimeout);
      final candidatePath = (savedPath ?? '').trim();
      final pathToUse = candidatePath.isEmpty ? targetPath : candidatePath;
      Log.i(tag, 'recaster.stop success savedPath=$savedPath pathToUse=$pathToUse');
      final file = File(pathToUse);
      if (!await _shouldKeepVideo(
        file,
        startTime: startTime,
        endTime: endTime,
      )) {
        return;
      }

      Log.i(tag, 'recaster.upload begin path=$pathToUse');
      await _uploadInChunks(
        reporterService,
        file: file,
        startTime: startTime,
        endTime: endTime,
      );
      Log.i(tag, 'recaster.upload success elapsedMs=${sw.elapsedMilliseconds}');
      await _deleteFileQuietly(file);
    } on TimeoutException catch (e, s) {
      Log.w(tag, 'recaster.stopOrUpload timeout e=$e s=$s');
      await _deleteFileQuietly(File(targetPath));
    } catch (e, s) {
      Log.w(tag, 'recaster.stopOrUpload failed e=${_shortError(e)} s=$s');
      await _deleteFileQuietly(File(targetPath));
    }
  }

  String _shortError(Object e) {
    final text = e.toString().replaceAll('\n', ' ').trim();
    return text.length > 400 ? '${text.substring(0, 400)}...' : text;
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
    final processId = _pidOrZero();
    final rand = Random().nextInt(1 << 20);
    return '$processId-$ts-$rand';
  }

  int _pidOrZero() {
    try {
      return pid;
    } catch (_) {
      return 0;
    }
  }
}

class _WorkerVideoRecordingServiceMacos
    extends _WorkerVideoRecordingServiceRecasterBase {
  static const _kTag = 'WorkerVideoRecordingServiceMacos';

  @override
  String get tag => _kTag;

  @override
  String get fileExtension => 'mp4';
}

class _WorkerVideoRecordingServiceWindows
    extends _WorkerVideoRecordingServiceRecasterBase {
  static const _kTag = 'WorkerVideoRecordingServiceWindows';

  @override
  String get tag => _kTag;

  @override
  String get fileExtension => 'mp4';
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

  @override
  String toString() =>
      '_CaptureRect{x: $x, y: $y, width: $width, height: $height}';
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
