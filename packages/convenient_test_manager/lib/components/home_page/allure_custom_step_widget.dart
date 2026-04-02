import 'dart:typed_data';

import 'package:convenient_test_manager/components/misc/state_indicator.dart';
import 'package:convenient_test_manager/misc/protobuf_extensions.dart';
import 'package:convenient_test_manager/stores/highlight_store.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager/stores/video_player_store.dart';
import 'package:convenient_test_manager_dart/stores/allure_custom_step_store.dart';
import 'package:convenient_test_manager_dart/stores/log_store.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_portal/flutter_portal.dart';
import 'package:get_it/get_it.dart';

class HomePageAllureCustomStepWidget extends StatelessWidget {
  final int order;
  final int testEntryId;
  final AllureCustomStepNode node;
  final int depth;

  const HomePageAllureCustomStepWidget({
    super.key,
    required this.order,
    required this.testEntryId,
    required this.node,
    required this.depth,
  });

  @override
  Widget build(BuildContext context) {
    final homePageStore = GetIt.I.get<HomePageStore>();
    const kScreenshotPeriod = 8;
    final screenshotIndexModPeriod = order % kScreenshotPeriod;
    return Observer(
      builder: (_) {
        return Row(
          children: [
            Expanded(
              flex: kScreenshotPeriod,
              child: _buildCore(context),
            ),
            if (!homePageStore.expandSecondaryPanel) ...[
              _buildSpacer(flex: screenshotIndexModPeriod),
              Expanded(
                flex: 1,
                child: _HomePageAllureCustomStepScreenshotPreview(
                  logEntryId: _calcInterestLogEntryId(),
                ),
              ),
              _buildSpacer(
                flex: kScreenshotPeriod - 1 - screenshotIndexModPeriod,
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildCore(BuildContext context) {
    final homePageStore = GetIt.I.get<HomePageStore>();
    final highlightStore = GetIt.I.get<HighlightStore>();
    final expanded = homePageStore.allureStepExpandMap[node.id];
    final detailsExpanded = homePageStore.allureStepDetailsExpandMap[node.id];
    final errorExpanded = homePageStore.allureStepErrorExpandMap[node.id];
    final hasLongError = _hasLongError(node.errorText);
    final hasParameterDetails = node.parameters.isNotEmpty;
    final active = _isActive(highlightStore.highlightLogEntryId);

    return Container(
      margin: const EdgeInsets.only(left: 32),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: _calcDecorationColor(context, active: active),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onHover: (hovering) {
              if (highlightStore.enableHoverMode && hovering) {
                _handleTapOrHover(targetState: true, fromHover: true);
              }
            },
            onTap: () {
              final targetState = !_isActive(highlightStore.highlightLogEntryId);
              _handleTapOrHover(targetState: targetState);
              if (hasParameterDetails) {
                homePageStore.allureStepDetailsExpandMap[node.id] =
                    !detailsExpanded;
              }
            },
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4, left: 8),
                    child: Text(
                      '$order',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 9,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: depth * 16),
                if (node.hasChildren)
                  InkWell(
                    onTap: () {
                      homePageStore.allureStepExpandMap[node.id] = !expanded;
                    },
                    child: Icon(
                      expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                      size: 18,
                    ),
                  )
                else
                  const SizedBox(width: 18),
                StateIndicatorWidget(
                  state: _stateForStatus(node.status),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        node.name,
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.25,
                        ),
                      ),
                      if (hasParameterDetails && detailsExpanded) ...[
                        const SizedBox(height: 4),
                        ...node.parameters.map(
                          (parameter) => Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              '${parameter.name}: ${parameter.value}',
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.2,
                                color: Theme.of(context).colorScheme.outline,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (node.parameterCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      '${node.parameterCount} parameters',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
                if (node.attachmentCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      '${node.attachmentCount} attachments',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (node.errorText?.trim().isNotEmpty ?? false)
            Padding(
              padding: EdgeInsets.only(left: 48 + depth * 16, top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .errorContainer
                          .withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      node.errorText!.trim(),
                      maxLines: errorExpanded ? null : 6,
                      overflow: errorExpanded
                          ? TextOverflow.visible
                          : TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.25,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (hasLongError)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: InkWell(
                        onTap: () {
                          homePageStore.allureStepErrorExpandMap[node.id] =
                              !errorExpanded;
                        },
                        child: Text(
                          errorExpanded ? '[Collapse]' : '[Expand]',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSpacer({required int flex}) =>
      flex <= 0 ? const SizedBox.shrink() : Spacer(flex: flex);

  Color _calcDecorationColor(BuildContext context, {required bool active}) {
    final colorScheme = Theme.of(context).colorScheme;
    final elevation = active ? 3.0 : 1.0;
    return ElevationOverlay.applySurfaceTint(
      colorScheme.surface,
      colorScheme.surfaceTint,
      elevation,
    );
  }

  bool _isActive(int? highlightLogEntryId) =>
      highlightLogEntryId != null &&
      node.linkedLogEntryIds.contains(highlightLogEntryId);

  int? _calcInterestLogEntryId() {
    final logStore = GetIt.I.get<LogStore>();
    for (final logEntryId in node.linkedLogEntryIds) {
      final snapshots = logStore.snapshotInLog[logEntryId];
      if (snapshots != null && snapshots.isNotEmpty) {
        return logEntryId;
      }
    }
    return node.linkedLogEntryIds.isEmpty ? null : node.linkedLogEntryIds.last;
  }

  void _handleTapOrHover({
    required bool targetState,
    bool fromHover = false,
  }) {
    final highlightStore = GetIt.I.get<HighlightStore>();
    final homePageStore = GetIt.I.get<HomePageStore>();
    final videoPlayerStore = GetIt.I.get<VideoPlayerStore>();

    if (fromHover) {
      highlightStore.suppressAutoJumpTemporarily();
    }

    homePageStore.previewAllureStepAttachments(
      targetState ? node.id : null,
      showLoading: targetState && node.attachments.isNotEmpty,
    );
    if (targetState &&
        node.attachments.isNotEmpty &&
        homePageStore.activeSecondaryPanelTab !=
            HomePageSecondaryPanelTab.attachments) {
      homePageStore.activeSecondaryPanelTab =
          HomePageSecondaryPanelTab.attachments;
    }

    final interestLogEntryId = _calcInterestLogEntryId();
    if (interestLogEntryId == null) {
      highlightStore.highlightLogEntryId = null;
      highlightStore.highlightTestEntryId = targetState ? testEntryId : null;
      return;
    }

    highlightStore.highlightLogEntryId = targetState ? interestLogEntryId : null;
    highlightStore.highlightTestEntryId = targetState ? testEntryId : null;

    if (targetState) {
      final logStore = GetIt.I.get<LogStore>();
      final activeVideo = videoPlayerStore.activeVideo;
      final logSubEntryIds = logStore.logSubEntryInEntry[interestLogEntryId];
      if (activeVideo != null &&
          logSubEntryIds != null &&
          logSubEntryIds.isNotEmpty) {
        final interestLogSubEntry = logStore.logSubEntryMap[logSubEntryIds.last];
        if (interestLogSubEntry != null) {
          videoPlayerStore.mainPlayerController.seek(
            activeVideo.absoluteToVideoTime(interestLogSubEntry.timeTyped),
          );
        }
      }
    }
  }

  SimplifiedStateEnum _stateForStatus(String status) {
    switch (status) {
      case 'passed':
        return SimplifiedStateEnum.completeSuccess;
      case 'failed':
      case 'broken':
        return SimplifiedStateEnum.completeFailureOrError;
      default:
        return SimplifiedStateEnum.pending;
    }
  }

  bool _hasLongError(String? errorText) {
    final text = errorText?.trim() ?? '';
    if (text.isEmpty) return false;
    return text.length > 240 || '\n'.allMatches(text).length >= 6;
  }
}

class _HomePageAllureCustomStepScreenshotPreview extends StatelessWidget {
  final int? logEntryId;

  const _HomePageAllureCustomStepScreenshotPreview({
    required this.logEntryId,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedLogEntryId = logEntryId;
    if (resolvedLogEntryId == null) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (_, constraints) => PortalTarget(
        anchor: const Aligned(
          follower: Alignment.topCenter,
          target: Alignment.topCenter,
        ),
        portalFollower: _buildPortalFollower(
          context,
          width: constraints.maxWidth,
          logEntryId: resolvedLogEntryId,
        ),
        child: const SizedBox(),
      ),
    );
  }

  Widget _buildPortalFollower(
    BuildContext context, {
    required double width,
    required int logEntryId,
  }) {
    final highlightStore = GetIt.I.get<HighlightStore>();
    final highlight = highlightStore.highlightLogEntryId == logEntryId;

    final snapshot = _calcInterestSnapshot(logEntryId);
    if (snapshot == null) return const SizedBox();

    return SizedBox(
      width: width,
      child: Container(
        decoration: BoxDecoration(
          border: highlight
              ? Border.all(color: Theme.of(context).primaryColor, width: 2)
              : Border.all(color: Colors.grey),
        ),
        child: Image.memory(snapshot.value),
      ),
    );
  }

  MapEntry<String, Uint8List>? _calcInterestSnapshot(int logEntryId) {
    final logStore = GetIt.I.get<LogStore>();
    final snapshots =
        logStore.snapshotInLog[logEntryId] ?? const <String, Uint8List>{};

    for (final key in const ['after', 'before']) {
      if (snapshots.containsKey(key)) {
        return MapEntry(key, snapshots[key]!);
      }
    }
    if (snapshots.isEmpty) return null;
    return snapshots.entries.first;
  }
}
