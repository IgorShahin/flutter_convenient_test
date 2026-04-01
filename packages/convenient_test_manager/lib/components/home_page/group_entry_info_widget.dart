import 'package:convenient_test_common/convenient_test_common.dart';
import 'package:convenient_test_manager/components/home_page/log_entry_widget.dart';
import 'package:convenient_test_manager/components/misc/state_indicator.dart';
import 'package:convenient_test_manager/misc/protobuf_extensions.dart';
import 'package:convenient_test_manager/services/misc_flutter_service.dart';
import 'package:convenient_test_manager/stores/highlight_store.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager/stores/video_player_store.dart';
import 'package:convenient_test_manager_dart/stores/log_store.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:get_it/get_it.dart';
import 'package:tuple/tuple.dart';

class HomePageGroupEntryInfoSectionBuilder extends StaticSectionBuilder {
  final int? groupEntryId;
  final int depth;
  final bool showHeader;

  const HomePageGroupEntryInfoSectionBuilder({
    required this.groupEntryId,
    required this.depth,
    this.showHeader = true,
  });

  @override
  Iterable<StaticSection> build() {
    final suiteInfoStore = GetIt.I.get<SuiteInfoStore>();

    final info = suiteInfoStore.suiteInfo?.entryMap[groupEntryId];
    if (info == null) return const [];

    if (info is GroupInfo) {
      return _GroupInfoSectionBuilder(
              info: info, depth: depth, showHeader: showHeader)
          .build();
    }
    if (info is TestInfo) {
      return _TestInfoSectionBuilder(info: info, depth: depth).build();
    }
    throw Exception('unknown info=$info');
  }
}

class _GroupInfoSectionBuilder extends StaticSectionBuilder {
  final GroupInfo info;
  final int depth;
  final bool showHeader;

  const _GroupInfoSectionBuilder({
    required this.info,
    required this.depth,
    this.showHeader = true,
  });

  @override
  Iterable<StaticSection> build() sync* {
    if (showHeader) {
      yield StaticSection.single(child: _buildHeader());
    }

    if (expanding || !showHeader) {
      for (final childGroupEntryId in info.entryIds) {
        yield* HomePageGroupEntryInfoSectionBuilder(
          groupEntryId: childGroupEntryId,
          depth: depth + 1,
        ).build();
      }
    }
  }

  Widget _buildHeader() {
    return Observer(builder: (_) {
      final highlightStore = GetIt.I.get<HighlightStore>();
      final suiteInfoStore = GetIt.I.get<SuiteInfoStore>();

      return InkWell(
        onTap: () {
          highlightStore
            ..enableAutoExpand = false
            ..expandGroupEntryMap[info.id] = !expanding;
        },
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: Padding(
            padding: const EdgeInsets.only(left: 8) +
                EdgeInsets.only(left: depth * 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 24,
                  height: 12,
                  child: Icon(
                    expanding ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                    size: 16,
                  ),
                ),
                Expanded(
                  child: Text(
                    info.calcBriefName(suiteInfoStore.suiteInfo!),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                ..._buildGroupStat(),
                _RunTestButton(
                    filterNameRegex: RegexUtils.matchPrefix(info.name)),
              ],
            ),
          ),
        ),
      );
    });
  }

  List<Widget> _buildGroupStat() {
    final suiteInfoStore = GetIt.I.get<SuiteInfoStore>();

    final stateCountMap = suiteInfoStore.calcStateCountMap(info);

    return SimplifiedStateEnum.values.expand<Widget>((state) {
      final count = stateCountMap[state];
      if (count == 0) return const [SizedBox.shrink()];

      return [
        Text('${count}x', style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 2),
        StateIndicatorWidget(state: state),
      ];
    }).toList();
  }

  bool get expanding =>
      GetIt.I.get<HighlightStore>().expandGroupEntryMap[info.id];
}

class _TestInfoSectionBuilder extends StaticSectionBuilder {
  static const _kTag = 'TestInfoSectionBuilder';

  final TestInfo info;
  final int depth;

  const _TestInfoSectionBuilder({
    required this.info,
    required this.depth,
  });

  @override
  Iterable<StaticSection> build() sync* {
    final suiteInfoStore = GetIt.I.get<SuiteInfoStore>();

    final state = suiteInfoStore.getSimplifiedState(info.id);

    yield StaticSection.single(child: _buildHeader(state));

    if (expanding) {
      yield* _buildLogEntries(state);
    }
  }

  Widget _buildHeader(SimplifiedStateEnum state) {
    final highlightStore = GetIt.I.get<HighlightStore>();
    final suiteInfoStore = GetIt.I.get<SuiteInfoStore>();

    return Observer(builder: (context) {
      return InkWell(
        onTap: () {
          highlightStore
            ..enableAutoExpand = false
            ..expandGroupEntryMap[info.id] = !expanding
            ..highlightTestEntryId = info.id;
        },
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4) +
                EdgeInsets.only(left: 16 + depth * 12),
            child: Row(
              children: [
                StateIndicatorWidget(
                  state: state,
                  enableAnimation: true,
                ),
                Text(
                  info.calcBriefName(suiteInfoStore.suiteInfo!),
                  style: const TextStyle(),
                ),
                Expanded(child: Container()),
                _buildPlayVideoButton(context),
                _RunTestButton(
                    filterNameRegex: RegexUtils.matchFull(info.name)),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildPlayVideoButton(BuildContext context) {
    if (logEntryIds.isEmpty) return const SizedBox.shrink();

    return IconButton(
      visualDensity: VisualDensity.compact,
      onPressed: () => _handleTapPlayVideoButton(context),
      tooltip: 'Play video recording',
      icon: const Icon(
        Icons.movie,
        color: Colors.teal,
        size: 16,
      ),
    );
  }

  Future<void> _handleTapPlayVideoButton(BuildContext context) async {
    final videoPlayerStore = GetIt.I.get<VideoPlayerStore>();
    final logStore = GetIt.I.get<LogStore>();
    final homePageStore = GetIt.I.get<HomePageStore>();

    final logSubEntryIds = logStore.logSubEntryInTest(info.id);
    if (logSubEntryIds.isEmpty) return;

    final logSubEntryTimes = logSubEntryIds
        .map((logSubEntryId) =>
            logStore.logSubEntryMap[logSubEntryId]!.timeTyped)
        .toList();

    final startTime = logSubEntryTimes.reduce((a, b) => a.isBefore(b) ? a : b);
    final endTime = logSubEntryTimes.reduce((a, b) => a.isAfter(b) ? a : b);
    final duration = endTime.difference(startTime);
    Log.d(_kTag,
        'handleTapPlayVideoButton startTime=$startTime endTime=$endTime');

    // to avoid minor time shifting causing wrong videos be included
    final searchStartTime = startTime.add(duration ~/ 10);
    final searchEndTime = endTime.subtract(duration ~/ 10);
    final candidateVideoIds = videoPlayerStore.videoMap
        .findVideosAtTimeRange(searchStartTime, searchEndTime);
    if (candidateVideoIds.isEmpty) {
      Log.w(
        _kTag,
        'handleTapPlayVideoButton no candidate videos for testId=${info.id} '
        'searchStartTime=$searchStartTime searchEndTime=$searchEndTime '
        'videoInfos=${videoPlayerStore.videoMap}',
      );
      return;
    }

    final interestVideoId = candidateVideoIds.length == 1
        ? candidateVideoIds.single
        : await showDialog<int>(
            context: context,
            builder: (_) => SimpleDialog(
              title: const Text('Choose video'),
              children: <Widget>[
                ...candidateVideoIds.map((candidateVideoId) {
                  final candidateVideo =
                      videoPlayerStore.videoMap[candidateVideoId]!;

                  return SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, candidateVideoId),
                    child: Text(
                        'Video at ${candidateVideo.startTime} ~ ${candidateVideo.endTime}'),
                  );
                })
              ],
            ),
          );
    if (interestVideoId == null) return;

    Log.d(_kTag,
        'handleTapPlayVideoButton interestVideoId=$interestVideoId videoInfos=${videoPlayerStore.videoMap}');
    final interestVideo = videoPlayerStore.videoMap[interestVideoId]!;
    videoPlayerStore
      ..activeVideoId = interestVideoId
      ..displayRange = Tuple2(interestVideo.absoluteToVideoTime(startTime),
          interestVideo.absoluteToVideoTime(endTime));

    homePageStore.activeSecondaryPanelTab = HomePageSecondaryPanelTab.video;
  }

  List<int> get logEntryIds =>
      GetIt.I.get<LogStore>().logEntryInTest[info.id] ?? <int>[];

  List<int> get visibleLogEntryIds {
    final logStore = GetIt.I.get<LogStore>();
    return logEntryIds
        .where((logEntryId) => !_isHttpOnlyLogEntry(logStore, logEntryId))
        .toList(growable: false);
  }

  Iterable<StaticSection> _buildLogEntries(SimplifiedStateEnum state) sync* {
    final logEntryIds = visibleLogEntryIds;

    if (logEntryIds.isEmpty) {
      yield StaticSection.single(
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
          child: Builder(
              builder: (context) => Text(
                    'No log entries for this test. This is usually because the test is not executed.',
                    style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline),
                  )),
        ),
      );
    } else {
      final setupEndExclusive = _calcSetupEndExclusive(logEntryIds);
      final setupGroupLabel = _calcSetupGroupLabel();
      yield StaticSection(
        metadata: TestInfoLogEntrySectionMetadata(
          testInfoId: info.id,
        ),
        count: logEntryIds.length,
        builder: (_, i) {
          return HomePageLogEntryWidget(
            order: i,
            testEntryId: info.id,
            logEntryId: logEntryIds[i],
            running: state == SimplifiedStateEnum.running &&
                i == logEntryIds.length - 1,
            isSetupPhase: i < setupEndExclusive,
            setupGroupLabel: setupGroupLabel,
          );
        },
      );
    }
  }

  int _calcSetupEndExclusive(List<int> logEntryIds) {
    final logStore = GetIt.I.get<LogStore>();
    for (var i = 0; i < logEntryIds.length; i++) {
      final subEntryIds = logStore.logSubEntryInEntry[logEntryIds[i]];
      if (subEntryIds == null) continue;
      final isStart = subEntryIds.any(
        (id) => logStore.logSubEntryMap[id]?.type == LogSubEntryType.TEST_START,
      );
      if (isStart) return i;
    }
    return logEntryIds.length;
  }

  bool _isHttpOnlyLogEntry(LogStore logStore, int logEntryId) {
    final subEntryIds = logStore.logSubEntryInEntry[logEntryId];
    if (subEntryIds == null || subEntryIds.isEmpty) {
      return false;
    }

    final subEntries = subEntryIds
        .map((id) => logStore.logSubEntryMap[id])
        .whereType<LogSubEntry>()
        .toList(growable: false);
    if (subEntries.isEmpty) {
      return false;
    }

    return subEntries.every((subEntry) {
      final title = subEntry.title.toUpperCase();
      return title.startsWith('HTTP') || title.contains('CHUCK');
    });
  }

  String _calcSetupGroupLabel() {
    final suiteInfo = GetIt.I.get<SuiteInfoStore>().suiteInfo;
    if (suiteInfo == null) return 'SETUP';

    final parts = <String>[];
    var parentId = suiteInfo.entryMap[info.id]?.parentId ?? -1;
    while (suiteInfo.isIdValid(parentId)) {
      final entry = suiteInfo.entryMap[parentId];
      if (entry is GroupInfo) {
        final name = entry.name.trim();
        if (name.isNotEmpty) {
          parts.add(name);
        }
      }
      parentId = entry?.parentId ?? -1;
    }
    if (parts.isEmpty) return 'SETUP';
    return 'SETUP [${parts.reversed.join(' / ')}]';
  }

  bool get expanding =>
      GetIt.I.get<HighlightStore>().expandGroupEntryMap[info.id];
}

@immutable
class TestInfoLogEntrySectionMetadata {
  final int testInfoId;

  const TestInfoLogEntrySectionMetadata({required this.testInfoId});
}

class _RunTestButton extends StatelessWidget {
  final String filterNameRegex;

  const _RunTestButton({required this.filterNameRegex});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      onPressed: () {
        GetIt.I.get<HighlightStore>().enableAutoExpand = true;
        GetIt.I
            .get<MiscFlutterService>()
            .hotRestartAndRunTests(filterNameRegex: filterNameRegex);
      },
      tooltip: 'Run this test',
      icon: const Icon(
        Icons.play_arrow,
        color: Colors.blue,
        size: 16,
      ),
    );
  }
}
