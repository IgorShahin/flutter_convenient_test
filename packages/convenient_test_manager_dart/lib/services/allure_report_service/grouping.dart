part of '../allure_report_service.dart';

List<Map<String, String>> _buildSuiteLabelsForTest({
  required SuiteInfo? suiteInfo,
  required String testName,
}) {
  final normalized = _compactGroupHierarchyNames(
      _suiteGroupNamesForTestInfo(suiteInfo, testName));
  if (normalized.isEmpty) return const [];

  final labels = <Map<String, String>>[];
  final seen = <String>{};
  void addLabel(String name, String value) {
    final clean = value.trim();
    if (clean.isEmpty) return;
    final key = '$name::$clean';
    if (!seen.add(key)) return;
    labels.add({'name': name, 'value': clean});
  }

  if (normalized.length == 1) {
    addLabel('suite', normalized.first);
  } else if (normalized.length == 2) {
    addLabel('parentSuite', normalized.first);
    addLabel('suite', normalized.last);
  } else {
    addLabel('parentSuite', normalized.first);
    addLabel('suite', normalized[1]);
    addLabel('subSuite', normalized.sublist(2).join(' / '));
  }

  addLabel('epic', normalized.first);
  addLabel('feature', normalized.first);
  if (normalized.length >= 2) {
    addLabel('story', normalized.sublist(1).join(' / '));
  }

  return labels;
}

List<String> _suiteGroupNamesForTestInfo(
    SuiteInfo? suiteInfo, String testName) {
  if (suiteInfo == null) return const [];
  final entryId = _resolveSuiteEntryIdForTestName(suiteInfo, testName);
  if (entryId == null) return const [];

  final groupNames = <String>[];
  var currentId = suiteInfo.entryMap[entryId]?.parentId ?? -1;
  while (suiteInfo.isIdValid(currentId)) {
    final entry = suiteInfo.entryMap[currentId];
    if (entry is GroupInfo && entry.name.trim().isNotEmpty) {
      groupNames.add(entry.name.trim());
    }
    currentId = entry?.parentId ?? -1;
  }
  return groupNames.reversed.toList();
}

String _displayNameForTestInfo({
  required SuiteInfo? suiteInfo,
  required String testName,
}) {
  final raw = () {
    if (suiteInfo == null) return testName;
    final entryId = _resolveSuiteEntryIdForTestName(suiteInfo, testName);
    if (entryId == null) return testName;
    final entry = suiteInfo.entryMap[entryId];
    if (entry is TestInfo && entry.name.trim().isNotEmpty) {
      return entry.name.trim();
    }
    return testName;
  }();
  return _stripGroupPrefixFromDisplayName(
    rawDisplayName: raw,
    suiteGroupNames: _compactGroupHierarchyNames(
        _suiteGroupNamesForTestInfo(suiteInfo, testName)),
  );
}

String _stripGroupPrefixFromDisplayName({
  required String rawDisplayName,
  required List<String> suiteGroupNames,
}) {
  var ans = rawDisplayName.trim();
  if (ans.isEmpty || suiteGroupNames.isEmpty) return ans;

  final orderedGroups = suiteGroupNames.toList()
    ..sort((a, b) => b.length.compareTo(a.length));

  var changed = true;
  while (changed) {
    changed = false;
    for (final groupName in orderedGroups) {
      final prefix = groupName.trim();
      if (prefix.isEmpty) continue;
      if (ans.length <= prefix.length) continue;
      if (ans.startsWith('$prefix ')) {
        ans = ans.substring(prefix.length).trimLeft();
        changed = true;
        break;
      }
    }
  }
  return ans;
}

void _decorateSetupFixtureByGroups({
  required _AllureTestRuntime runtime,
  required List<String> suiteGroupNames,
}) {
  final setupFixture = runtime.beforeFixtures['SETUP'];
  if (setupFixture == null) return;

  final visibleSteps = setupFixture.steps.where((step) {
    final stepNameRaw = (step['name'] as String?)?.trim() ?? '';
    return !_isSetupSeparatorStep(stepNameRaw);
  }).toList();

  if (visibleSteps.isEmpty) {
    setupFixture.steps.clear();
    return;
  }

  if (visibleSteps.length == 1) {
    setupFixture.steps
      ..clear()
      ..addAll(visibleSteps);
    return;
  }

  final compactedGroupNames = _compactGroupHierarchyNames(suiteGroupNames);
  final blocks = <List<Map<String, dynamic>>>[];
  var currentBlock = <Map<String, dynamic>>[];
  for (final step in visibleSteps) {
    final stepNameRaw = (step['name'] as String?)?.trim() ?? '';
    if (_isSetupSeparatorStep(stepNameRaw) && currentBlock.isNotEmpty) {
      blocks.add(currentBlock);
      currentBlock = <Map<String, dynamic>>[];
      continue;
    }
    if (_isSetupSeparatorStep(stepNameRaw)) {
      continue;
    }
    currentBlock.add(step);
  }
  if (currentBlock.isNotEmpty) {
    blocks.add(currentBlock);
  }
  if (blocks.length <= 1) {
    setupFixture.steps
      ..clear()
      ..addAll(visibleSteps);
    return;
  }

  final wrappers = <Map<String, dynamic>>[];
  final offset = max(0, compactedGroupNames.length - blocks.length);
  for (var i = 0; i < blocks.length; i++) {
    final block = blocks[i];
    final start = (block.first['start'] as int?) ?? runtime.startMs;
    final stop = (block.last['stop'] as int?) ?? runtime.stopMs;
    final groupName = (i + offset < compactedGroupNames.length)
        ? compactedGroupNames[i + offset]
        : 'group-${i + 1}';
    final hasFailed = block.any((e) =>
        (e['status'] as String?) == 'failed' ||
        (e['status'] as String?) == 'broken');
    wrappers.add({
      'name': groupName,
      'status': hasFailed ? 'failed' : 'passed',
      'stage': 'finished',
      'start': start,
      'stop': stop,
      'steps': block,
    });
  }
  setupFixture.steps
    ..clear()
    ..addAll(wrappers);
}

bool _isSetupSeparatorStep(String rawName) {
  final name = rawName.trim().toUpperCase();
  if (name == 'SETUP') return true;
  if (name.startsWith('SETUP ')) return true;
  if (name.startsWith('SETUP[')) return true;
  if (name.startsWith('SETUP(')) return true;
  return false;
}

List<String> _compactGroupHierarchyNames(List<String> rawGroupNames) {
  if (rawGroupNames.isEmpty) return const [];
  final compacted = <String>[];
  for (final raw in rawGroupNames) {
    var name = raw.trim();
    if (name.isEmpty) continue;
    for (final parent in compacted) {
      final prefix = parent.trim();
      if (prefix.isEmpty) continue;
      if (name.length > prefix.length && name.startsWith('$prefix ')) {
        name = name.substring(prefix.length).trimLeft();
        break;
      }
    }
    compacted.add(name);
  }
  return compacted;
}

int? _resolveSuiteEntryIdForTestName(SuiteInfo suiteInfo, String testName) {
  final exact = suiteInfo.getEntryIdFromName(testName);
  if (exact != null) return exact;

  final normalizedTestName = _normalizeSuiteName(testName);
  if (normalizedTestName.isEmpty) return null;

  int? bestId;
  var bestScore = -1;
  for (final entry in suiteInfo.entryMap.entries) {
    if (entry.value is! TestInfo) continue;
    final candidateName = entry.value.name;
    final normalizedCandidate = _normalizeSuiteName(candidateName);
    if (normalizedCandidate.isEmpty) continue;

    var score = -1;
    if (normalizedCandidate == normalizedTestName) {
      score = 100000 + normalizedCandidate.length;
    } else if (normalizedTestName.endsWith(normalizedCandidate) &&
        (normalizedTestName.length == normalizedCandidate.length ||
            normalizedTestName[normalizedTestName.length -
                    normalizedCandidate.length -
                    1] ==
                ' ')) {
      score = 10000 + normalizedCandidate.length;
    } else if (normalizedTestName.contains(normalizedCandidate)) {
      score = normalizedCandidate.length;
    }

    if (score > bestScore) {
      bestScore = score;
      bestId = entry.key;
    }
  }

  return bestScore >= 0 ? bestId : null;
}

String _normalizeSuiteName(String input) {
  final lower = input.trim().toLowerCase();
  if (lower.isEmpty) return '';
  return lower.replaceAll(RegExp(r'\s+'), ' ');
}
