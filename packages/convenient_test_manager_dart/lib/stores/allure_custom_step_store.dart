import 'package:mobx/mobx.dart';

class AllureCustomStepStore {
  final rootStepIdsByTest = ObservableMap<int, ObservableList<String>>();
  final openStepIdsByTest = ObservableMap<int, ObservableList<String>>();
  final stepMap = ObservableMap<String, AllureCustomStepNode>();
  final testIdOfStep = ObservableMap<String, int>();

  void clear() {
    rootStepIdsByTest.clear();
    openStepIdsByTest.clear();
    stepMap.clear();
    testIdOfStep.clear();
  }

  bool hasStepsForTest(
    int testEntryId, {
    AllureCustomStepSection? section,
  }) =>
      rootStepIdsForTest(testEntryId, section: section).isNotEmpty;

  List<String> rootStepIdsForTest(
    int testEntryId, {
    AllureCustomStepSection? section,
  }) {
    final ids =
        List<String>.from(rootStepIdsByTest[testEntryId] ?? const <String>[]);
    if (section == null) return ids;
    return ids
        .where((id) => stepMap[id]?.section == section)
        .toList(growable: false);
  }

  AllureCustomStepNode? stepById(String id) => stepMap[id];

  void startStep({
    required int testEntryId,
    required String id,
    required String name,
    required AllureCustomStepSection section,
  }) {
    final openIds =
        openStepIdsByTest.putIfAbsent(testEntryId, ObservableList<String>.new);
    final rootIds =
        rootStepIdsByTest.putIfAbsent(testEntryId, ObservableList<String>.new);
    final parentId = openIds.isEmpty ? null : openIds.last;
    final effectiveSection =
        parentId == null ? section : (stepMap[parentId]?.section ?? section);
    stepMap[id] = AllureCustomStepNode(
      id: id,
      name: name,
      parentId: parentId,
      section: effectiveSection,
    );
    testIdOfStep[id] = testEntryId;
    if (parentId == null) {
      rootIds.add(id);
    } else {
      final parent = stepMap[parentId];
      if (parent != null) {
        stepMap[parentId] = parent.copyWith(
          childIds: [...parent.childIds, id],
        );
      } else {
        rootIds.add(id);
      }
    }
    openIds.add(id);
  }

  void endStep({
    required int testEntryId,
    required String id,
    required String status,
  }) {
    final node = stepMap[id];
    if (node == null) return;
    stepMap[id] = node.copyWith(
      status: _mergeStatus(node.status, status),
      finished: true,
    );
    _bubbleStatus(id, status);

    final openIds = openStepIdsByTest[testEntryId];
    if (openIds != null) {
      openIds.remove(id);
    }
  }

  void addParameter({
    required String id,
  }) {
    final node = stepMap[id];
    if (node == null) return;
    stepMap[id] = node.copyWith(parameterCount: node.parameterCount + 1);
  }

  void addAttachment({
    required String id,
  }) {
    final node = stepMap[id];
    if (node == null) return;
    stepMap[id] = node.copyWith(attachmentCount: node.attachmentCount + 1);
  }

  void _bubbleStatus(String stepId, String status) {
    var currentId = stepMap[stepId]?.parentId;
    while (currentId != null) {
      final current = stepMap[currentId];
      if (current == null) {
        break;
      }
      stepMap[currentId] = current.copyWith(
        status: _mergeStatus(current.status, status),
      );
      currentId = current.parentId;
    }
  }

  String _mergeStatus(String current, String incoming) {
    if (incoming == 'broken' || current == 'broken') {
      return 'broken';
    }
    if (incoming == 'failed' || current == 'failed') {
      return 'failed';
    }
    if (incoming == 'passed') {
      return current == 'pending' ? 'passed' : current;
    }
    return current;
  }
}

class AllureCustomStepNode {
  final String id;
  final String name;
  final String status;
  final String? parentId;
  final List<String> childIds;
  final int parameterCount;
  final int attachmentCount;
  final bool finished;
  final AllureCustomStepSection section;

  const AllureCustomStepNode({
    required this.id,
    required this.name,
    required this.section,
    this.status = 'pending',
    this.parentId,
    this.childIds = const <String>[],
    this.parameterCount = 0,
    this.attachmentCount = 0,
    this.finished = false,
  });

  bool get hasChildren => childIds.isNotEmpty;

  AllureCustomStepNode copyWith({
    String? name,
    String? status,
    String? parentId,
    List<String>? childIds,
    int? parameterCount,
    int? attachmentCount,
    bool? finished,
    AllureCustomStepSection? section,
  }) {
    return AllureCustomStepNode(
      id: id,
      name: name ?? this.name,
      section: section ?? this.section,
      status: status ?? this.status,
      parentId: parentId ?? this.parentId,
      childIds: childIds ?? this.childIds,
      parameterCount: parameterCount ?? this.parameterCount,
      attachmentCount: attachmentCount ?? this.attachmentCount,
      finished: finished ?? this.finished,
    );
  }
}

enum AllureCustomStepSection {
  setup,
  body,
  teardown,
}
