part of '../allure_report_service.dart';

class _PendingSnapshot {
  final String name;
  final Uint8List image;

  const _PendingSnapshot({
    required this.name,
    required this.image,
  });
}

class _PendingTextAttachment {
  final String name;
  final String content;

  const _PendingTextAttachment({
    required this.name,
    required this.content,
  });
}

class _AllureTestRuntime {
  final String uuid;
  final String historyId;
  final String testName;
  final String fullName;
  final int attemptIndex;
  final List<Map<String, dynamic>> steps = [];
  final List<Map<String, dynamic>> attachments = [];
  final Set<String> customTags = {};
  final Set<String> errorSignatures = {};
  final List<String> openAllureStepIds = [];
  final Map<String, Map<String, dynamic>> allureStepsById = {};
  final Map<String, _AllureFixtureRuntime> beforeFixtures = {};
  final Map<String, _AllureFixtureRuntime> afterFixtures = {};
  final StringBuffer logBuffer = StringBuffer();
  String? resultPath;
  String? status;
  Map<String, dynamic>? statusDetails;
  _AllureStepPointer? pendingHttpCheckPointer;
  bool finished = false;
  bool hasSeenBodyStart = false;

  int? _startMs;
  int? _stopMs;

  _AllureTestRuntime({
    required this.uuid,
    required this.testName,
    required this.fullName,
    required this.attemptIndex,
  }) : historyId = testName;

  int get startMs => _startMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;

  int get stopMs => _stopMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;

  void touchAt(int ms) {
    _startMs = _startMs == null ? ms : min(_startMs!, ms);
    _stopMs = _stopMs == null ? ms : max(_stopMs!, ms);
  }

  _AllureFixtureRuntime ensureBeforeFixture(String name) =>
      beforeFixtures.putIfAbsent(name, () => _AllureFixtureRuntime(name: name));

  _AllureFixtureRuntime ensureAfterFixture(String name) =>
      afterFixtures.putIfAbsent(name, () => _AllureFixtureRuntime(name: name));
}

class _AllureFixtureRuntime {
  final String name;
  final List<Map<String, dynamic>> steps = [];
  final List<Map<String, dynamic>> attachments = [];
  String? _status;
  int? _startMs;
  int? _stopMs;

  _AllureFixtureRuntime({required this.name});

  bool get hasRenderableContent =>
      _buildDisplaySteps().isNotEmpty || attachments.isNotEmpty;

  void absorbStep(Map<String, dynamic> step) {
    final stepStatus = (step['status'] as String?) ?? 'passed';
    if (stepStatus == 'failed' || stepStatus == 'broken') {
      _status = 'failed';
    } else {
      _status ??= 'passed';
    }

    final start = step['start'] as int?;
    final stop = step['stop'] as int?;
    if (start != null || stop != null) {
      touchRange(
        start: start ?? stop ?? _nowMs(),
        stop: stop ?? start ?? _nowMs(),
      );
    }
  }

  void touchRange({
    required int start,
    required int stop,
  }) {
    _startMs = _startMs == null ? start : min(_startMs!, start);
    _stopMs = _stopMs == null ? stop : max(_stopMs!, stop);
  }

  int _nowMs() => DateTime.now().toUtc().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'name': name,
        'status': _status ?? 'passed',
        'stage': 'finished',
        'start': _startMs ?? _nowMs(),
        'stop': _stopMs ?? _nowMs(),
        'steps': _buildDisplaySteps(),
        'attachments': attachments,
      };

  List<Map<String, dynamic>> _buildDisplaySteps() {
    return steps;
  }
}

enum _AllureHookSection { body, before, after }

class _AllureHookRouting {
  final _AllureHookSection section;
  final String? fixtureName;

  const _AllureHookRouting.body()
      : section = _AllureHookSection.body,
        fixtureName = null;

  const _AllureHookRouting.before(this.fixtureName)
      : section = _AllureHookSection.before;

  const _AllureHookRouting.after(this.fixtureName)
      : section = _AllureHookSection.after;
}

class _AllureStepPointer {
  final _AllureHookSection section;
  final int index;
  final String? fixtureName;

  const _AllureStepPointer.body({
    required this.index,
  })  : section = _AllureHookSection.body,
        fixtureName = null;

  const _AllureStepPointer.before({
    required this.fixtureName,
    required this.index,
  }) : section = _AllureHookSection.before;

  const _AllureStepPointer.after({
    required this.fixtureName,
    required this.index,
  }) : section = _AllureHookSection.after;
}
