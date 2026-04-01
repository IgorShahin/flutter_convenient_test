import 'dart:convert';
import 'dart:io';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/misc/runtime_platform.dart';
import 'package:path_provider/path_provider.dart';

class WorkerVmEndpoint {
  final String host;
  final int port;

  const WorkerVmEndpoint({
    required this.host,
    required this.port,
  });

  String get displayName => '$host:$port';

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
      };

  static WorkerVmEndpoint? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final host = (json['host'] as String?)?.trim();
    final port = json['port'];
    if (host == null || host.isEmpty || port is! int) return null;
    if (port < 1 || port > 65535) return null;
    return WorkerVmEndpoint(host: host, port: port);
  }
}

class WorkerVmEndpointHistoryService {
  static const _kTag = 'WorkerVmEndpointHistoryService';
  static const _kHistoryFileName = 'worker_vm_endpoints.json';
  static const _kMaxHistory = 12;

  List<WorkerVmEndpoint> get history => List.unmodifiable(_history);
  WorkerVmEndpoint? get lastUsed => _lastUsed;

  final List<WorkerVmEndpoint> _history = [];
  WorkerVmEndpoint? _lastUsed;

  Future<void> load() async {
    if (!supportsIoPlatform) return;
    try {
      final file = await _historyFile();
      if (!await file.exists()) return;

      final rawText = await file.readAsString();
      final json = jsonDecode(rawText);
      if (json is! Map<String, dynamic>) return;

      final loadedHistory = (json['history'] as List<dynamic>? ?? const [])
          .map(WorkerVmEndpoint.fromJson)
          .whereType<WorkerVmEndpoint>()
          .toList();
      final loadedLast = WorkerVmEndpoint.fromJson(json['last_used']);

      _history
        ..clear()
        ..addAll(_dedupAndClamp(loadedHistory));
      _lastUsed = loadedLast;
    } catch (e, s) {
      Log.w(_kTag, 'load failed e=$e s=$s');
    }
  }

  Future<void> remember(WorkerVmEndpoint endpoint) async {
    _lastUsed = endpoint;
    _history
      ..removeWhere(
        (e) => e.host == endpoint.host && e.port == endpoint.port,
      )
      ..insert(0, endpoint);
    if (_history.length > _kMaxHistory) {
      _history.removeRange(_kMaxHistory, _history.length);
    }
    await _save();
  }

  Future<void> _save() async {
    if (!supportsIoPlatform) return;
    try {
      final file = await _historyFile();
      final data = {
        'history': _history.map((e) => e.toJson()).toList(),
        'last_used': _lastUsed?.toJson(),
      };
      await file.writeAsString(jsonEncode(data));
    } catch (e, s) {
      Log.w(_kTag, 'save failed e=$e s=$s');
    }
  }

  List<WorkerVmEndpoint> _dedupAndClamp(List<WorkerVmEndpoint> input) {
    final seen = <String>{};
    final deduped = <WorkerVmEndpoint>[];
    for (final e in input) {
      final key = '${e.host}:${e.port}';
      if (seen.contains(key)) continue;
      seen.add(key);
      deduped.add(e);
      if (deduped.length >= _kMaxHistory) break;
    }
    return deduped;
  }

  Future<File> _historyFile() async {
    final baseDir = await getApplicationSupportDirectory();
    final managerDir = Directory('${baseDir.path}/convenient_test_manager');
    await managerDir.create(recursive: true);
    return File('${managerDir.path}/$_kHistoryFileName');
  }
}
