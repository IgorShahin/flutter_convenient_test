part of '../allure_report_service.dart';

List<File> _matchVideosForRuntime({
  required _AllureTestRuntime runtime,
  required List<File> candidates,
}) {
  const leadLagToleranceMs = 5 * 60 * 1000;
  final matched = <File>[];
  for (final file in candidates) {
    final stat = file.statSync();
    final endMs = stat.modified.toUtc().millisecondsSinceEpoch;
    final startHintMs = _videoStartHintMsFromPath(file.path);
    final overlaps = endMs >= runtime.startMs - leadLagToleranceMs &&
        (startHintMs ?? endMs) <= runtime.stopMs + leadLagToleranceMs;
    if (overlaps) {
      matched.add(file);
    }
  }

  if (matched.isNotEmpty) return matched;

  final nearest = candidates
      .map((f) => MapEntry(
            f,
            (f.statSync().modified.toUtc().millisecondsSinceEpoch -
                    runtime.stopMs)
                .abs(),
          ))
      .toList()
    ..sort((a, b) => a.value.compareTo(b.value));
  if (nearest.isNotEmpty && nearest.first.value <= 60 * 1000) {
    return [nearest.first.key];
  }
  return const [];
}

int? _videoStartHintMsFromPath(String path) {
  final fileName = path.split(Platform.pathSeparator).isEmpty
      ? path
      : path.split(Platform.pathSeparator).last;
  final match = RegExp(r'(\d{8}_\d{6})').firstMatch(fileName);
  if (match == null) return null;

  final token = match.group(1);
  if (token == null) return null;
  try {
    final y = int.parse(token.substring(0, 4));
    final m = int.parse(token.substring(4, 6));
    final d = int.parse(token.substring(6, 8));
    final hh = int.parse(token.substring(9, 11));
    final mm = int.parse(token.substring(11, 13));
    final ss = int.parse(token.substring(13, 15));
    return DateTime(y, m, d, hh, mm, ss).toUtc().millisecondsSinceEpoch;
  } catch (_) {
    return null;
  }
}

int _usToMs(int value) => value ~/ 1000;

String _detectImageExtension(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'jpg';
  }
  return 'bin';
}

String _mimeTypeForExtension(String extension) {
  switch (extension) {
    case 'png':
      return 'image/png';
    case 'jpg':
      return 'image/jpeg';
    default:
      return 'application/octet-stream';
  }
}

String _pathExtension(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return 'bin';
  return path.substring(dot + 1).toLowerCase();
}

String _videoMimeTypeForExtension(String extension) {
  switch (extension) {
    case 'mp4':
      return 'video/mp4';
    case 'mov':
      return 'video/quicktime';
    case 'webm':
      return 'video/webm';
    case 'mkv':
      return 'video/x-matroska';
    default:
      return 'application/octet-stream';
  }
}
