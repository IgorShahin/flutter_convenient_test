import 'dart:convert';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager/components/misc/enhanced_selectable_text.dart';
import 'package:convenient_test_manager/stores/highlight_store.dart';
import 'package:convenient_test_manager_dart/stores/log_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:get_it/get_it.dart';

class HomePageRequestLogPanel extends StatefulWidget {
  const HomePageRequestLogPanel({super.key});

  @override
  State<HomePageRequestLogPanel> createState() =>
      _HomePageRequestLogPanelState();
}

class _HomePageRequestLogPanelState extends State<HomePageRequestLogPanel> {
  int? _selectedLogEntryId;
  _TraceDetailsTab _detailsTab = _TraceDetailsTab.overview;

  @override
  Widget build(BuildContext context) {
    final highlightStore = GetIt.I.get<HighlightStore>();
    final logStore = GetIt.I.get<LogStore>();

    return Observer(
      builder: (_) {
        final highlightTestEntryId = highlightStore.highlightTestEntryId;
        if (highlightTestEntryId == null) {
          return const Center(
            child: Text('Выбери лог теста слева, чтобы открыть HTTP запросы'),
          );
        }

        final traces = _collectHttpTraces(
          logStore: logStore,
          testEntryId: highlightTestEntryId,
        );
        if (traces.isEmpty) {
          return const Center(
            child: Text(
              'Для выбранного теста нет HTTP-запросов.\n'
              'Подключи createConvenientTestManagerInterceptor() к Dio.',
              textAlign: TextAlign.center,
            ),
          );
        }

        final selectedTrace = traces.firstWhereOrNull(
              (trace) => trace.logEntryId == _selectedLogEntryId,
            ) ??
            traces.first;

        return LayoutBuilder(
          builder: (context, constraints) {
            final useHorizontalLayout = constraints.maxWidth >= 920;
            if (useHorizontalLayout) {
              return Row(
                children: [
                  SizedBox(
                    width: 340,
                    child: _TraceListPane(
                      traces: traces,
                      selectedLogEntryId: selectedTrace.logEntryId,
                      onSelected: _handleTraceSelected,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: _TraceDetailsPane(
                      trace: selectedTrace,
                      detailsTab: _detailsTab,
                      onTabSelected: _handleTabSelected,
                    ),
                  ),
                ],
              );
            }

            return Column(
              children: [
                SizedBox(
                  height: 240,
                  child: _TraceListPane(
                    traces: traces,
                    selectedLogEntryId: selectedTrace.logEntryId,
                    onSelected: _handleTraceSelected,
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _TraceDetailsPane(
                    trace: selectedTrace,
                    detailsTab: _detailsTab,
                    onTabSelected: _handleTabSelected,
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _handleTraceSelected(int logEntryId) {
    setState(() {
      _selectedLogEntryId = logEntryId;
      _detailsTab = _TraceDetailsTab.overview;
    });
  }

  void _handleTabSelected(_TraceDetailsTab tab) {
    setState(() => _detailsTab = tab);
  }

  List<_HttpTrace> _collectHttpTraces({
    required LogStore logStore,
    required int testEntryId,
  }) {
    final logEntryIds = logStore.logEntryInTest[testEntryId] ?? const <int>[];
    final traces = <_HttpTrace>[];
    for (final logEntryId in logEntryIds) {
      final subEntryIds =
          logStore.logSubEntryInEntry[logEntryId] ?? const <int>[];
      final httpSubEntries = subEntryIds
          .map((id) => logStore.logSubEntryMap[id])
          .whereType<LogSubEntry>()
          .where(_isHttpSubEntry)
          .toList();
      if (httpSubEntries.isEmpty) {
        continue;
      }
      traces.add(_HttpTrace.fromSubEntries(logEntryId, httpSubEntries));
    }
    return traces.reversed.toList();
  }

  static bool _isHttpSubEntry(LogSubEntry sub) {
    final title = sub.title.toUpperCase();
    return title.startsWith('HTTP') || title.contains('CHUCK');
  }
}

enum _TraceDetailsTab {
  overview,
  request,
  response,
  error,
  timeline,
}

extension on _TraceDetailsTab {
  String get title {
    switch (this) {
      case _TraceDetailsTab.overview:
        return 'Overview';
      case _TraceDetailsTab.request:
        return 'Request';
      case _TraceDetailsTab.response:
        return 'Response';
      case _TraceDetailsTab.error:
        return 'Error';
      case _TraceDetailsTab.timeline:
        return 'Timeline';
    }
  }
}

class _HttpTrace {
  _HttpTrace({
    required this.logEntryId,
    required this.timeline,
    required this.requestLine,
    required this.responseLine,
    required this.errorLine,
    required this.requestPayload,
    required this.responsePayload,
    required this.errorPayload,
    required this.method,
    required this.path,
    required this.requestId,
    required this.statusCode,
    required this.durationMs,
  });

  factory _HttpTrace.fromSubEntries(
      int logEntryId, List<LogSubEntry> subEntries) {
    final requestLineEntry = subEntries.firstWhereOrNull(
      (entry) => entry.title.contains('➡️'),
    );
    final responseLineEntry = subEntries.lastWhereOrNull(
      (entry) => entry.title.contains('⬅️'),
    );
    final requestPayloadEntry = subEntries.lastWhereOrNull(
      (entry) => entry.title.toLowerCase().endsWith('body'),
    );
    final responsePayloadEntry = subEntries.lastWhereOrNull(
      (entry) => entry.title.toLowerCase().endsWith('resp'),
    );
    final errorPayloadEntry = subEntries.lastWhereOrNull(
      (entry) => entry.title.toLowerCase().endsWith('error'),
    );

    final requestMatch = requestLineEntry == null
        ? null
        : _requestLineRegExp.firstMatch(requestLineEntry.title);
    final responseMatch = responseLineEntry == null
        ? null
        : _responseLineRegExp.firstMatch(responseLineEntry.title);

    final method = responseMatch?.namedGroup('method') ??
        requestMatch?.namedGroup('method') ??
        'HTTP';
    final path = responseMatch?.namedGroup('path') ??
        requestMatch?.namedGroup('path') ??
        requestLineEntry?.title ??
        'Unknown';
    final requestId =
        responseMatch?.namedGroup('id') ?? requestMatch?.namedGroup('id');
    final statusText = responseMatch?.namedGroup('status');
    final statusCode =
        statusText == null ? null : int.tryParse(statusText.split(' ').first);
    final durationMs =
        int.tryParse(responseMatch?.namedGroup('durationMs') ?? '');

    return _HttpTrace(
      logEntryId: logEntryId,
      timeline: subEntries,
      requestLine: requestLineEntry?.title,
      responseLine: responseLineEntry?.title,
      errorLine: errorPayloadEntry?.title,
      requestPayload: requestPayloadEntry?.message,
      responsePayload: responsePayloadEntry?.message,
      errorPayload: errorPayloadEntry?.message,
      method: method,
      path: path,
      requestId: requestId,
      statusCode: statusCode,
      durationMs: durationMs,
    );
  }

  final int logEntryId;
  final List<LogSubEntry> timeline;
  final String? requestLine;
  final String? responseLine;
  final String? errorLine;
  final String? requestPayload;
  final String? responsePayload;
  final String? errorPayload;
  final String method;
  final String path;
  final String? requestId;
  final int? statusCode;
  final int? durationMs;

  bool get hasError =>
      (errorPayload?.trim().isNotEmpty ?? false) ||
      statusCode == null ||
      (statusCode ?? 0) >= 400;
}

final _requestLineRegExp = RegExp(
  r'^HTTP(?:\s+#(?<id>\d+))?\s+➡️\s+(?<method>[A-Z]+)\s+(?<path>.+)$',
);

final _responseLineRegExp = RegExp(
  r'^HTTP(?:\s+#(?<id>\d+))?\s+⬅️\s+(?<status>[0-9]+(?:\s+ERROR)?|ERROR)\s+(?<method>[A-Z]+)\s+(?<path>.+?)(?:\s+\((?<durationMs>\d+)ms\))?$',
);

class _TraceListPane extends StatelessWidget {
  const _TraceListPane({
    required this.traces,
    required this.selectedLogEntryId,
    required this.onSelected,
  });

  final List<_HttpTrace> traces;
  final int selectedLogEntryId;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: traces.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final trace = traces[index];
        final selected = trace.logEntryId == selectedLogEntryId;
        return _TraceListTile(
          trace: trace,
          selected: selected,
          onTap: () => onSelected(trace.logEntryId),
        );
      },
    );
  }
}

class _TraceListTile extends StatelessWidget {
  const _TraceListTile({
    required this.trace,
    required this.selected,
    required this.onTap,
  });

  final _HttpTrace trace;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final borderColor =
        selected ? colorScheme.primary : colorScheme.outlineVariant;
    final background = selected
        ? colorScheme.primaryContainer.withValues(alpha: 0.45)
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.25);

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _MethodBadge(method: trace.method),
                  const SizedBox(width: 8),
                  _StatusBadge(
                      statusCode: trace.statusCode, hasError: trace.hasError),
                  const Spacer(),
                  Text(
                    trace.durationMs == null ? '...' : '${trace.durationMs} ms',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                trace.path,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'RobotoMono',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Log #${trace.logEntryId}${trace.requestId == null ? '' : ' • Req #${trace.requestId}'}',
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TraceDetailsPane extends StatelessWidget {
  const _TraceDetailsPane({
    required this.trace,
    required this.detailsTab,
    required this.onTabSelected,
  });

  final _HttpTrace trace;
  final _TraceDetailsTab detailsTab;
  final ValueChanged<_TraceDetailsTab> onTabSelected;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: _TraceHeader(trace: trace),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ToggleButtons(
              isSelected: _TraceDetailsTab.values
                  .map((tab) => tab == detailsTab)
                  .toList(),
              onPressed: (index) =>
                  onTabSelected(_TraceDetailsTab.values[index]),
              children: _TraceDetailsTab.values
                  .map(
                    (tab) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(tab.title),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: _buildTabContent(context),
          ),
        ),
      ],
    );
  }

  Widget _buildTabContent(BuildContext context) {
    switch (detailsTab) {
      case _TraceDetailsTab.overview:
        return _TraceOverview(trace: trace);
      case _TraceDetailsTab.request:
        return _ScrollableCodeBlock(
          text:
              _prettifyPayload(trace.requestPayload) ?? 'Request body is empty',
        );
      case _TraceDetailsTab.response:
        return _ScrollableCodeBlock(
          text: _prettifyPayload(trace.responsePayload) ??
              'Response body is empty',
        );
      case _TraceDetailsTab.error:
        return _ScrollableCodeBlock(
          text: _prettifyPayload(trace.errorPayload) ?? 'Error is empty',
        );
      case _TraceDetailsTab.timeline:
        return ListView.separated(
          itemCount: trace.timeline.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) =>
              _TimelineTile(subEntry: trace.timeline[index]),
        );
    }
  }
}

class _TraceHeader extends StatelessWidget {
  const _TraceHeader({required this.trace});

  final _HttpTrace trace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _MethodBadge(method: trace.method),
            const SizedBox(width: 8),
            _StatusBadge(
                statusCode: trace.statusCode, hasError: trace.hasError),
            const SizedBox(width: 8),
            Text(
              trace.durationMs == null ? '...' : '${trace.durationMs} ms',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          trace.path,
          style: const TextStyle(
            fontFamily: 'RobotoMono',
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

class _TraceOverview extends StatelessWidget {
  const _TraceOverview({required this.trace});

  final _HttpTrace trace;

  @override
  Widget build(BuildContext context) {
    final rows = <MapEntry<String, String>>[
      MapEntry('Method', trace.method),
      MapEntry('Path', trace.path),
      MapEntry('Status', trace.statusCode?.toString() ?? 'Pending/Error'),
      MapEntry('Duration',
          trace.durationMs == null ? 'Unknown' : '${trace.durationMs} ms'),
      MapEntry('Log Entry', '#${trace.logEntryId}'),
      if (trace.requestId != null) MapEntry('Request ID', trace.requestId!),
      if (trace.requestLine != null)
        MapEntry('Request Line', trace.requestLine!),
      if (trace.responseLine != null)
        MapEntry('Response Line', trace.responseLine!),
      if (trace.errorLine != null) MapEntry('Error Line', trace.errorLine!),
    ];

    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final row = rows[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.key,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 4),
              _InlineScrollableText(text: row.value),
            ],
          ),
        );
      },
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.subEntry});

  final LogSubEntry subEntry;

  @override
  Widget build(BuildContext context) {
    final timeText = DateTime.fromMicrosecondsSinceEpoch(subEntry.time.toInt())
        .toIso8601String();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            subEntry.title,
            style: const TextStyle(
              fontFamily: 'RobotoMono',
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            timeText,
            style: Theme.of(context).textTheme.labelSmall,
          ),
          if (subEntry.message.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            _ScrollableCodeBlock(
                text: _prettifyPayload(subEntry.message) ?? ''),
          ],
        ],
      ),
    );
  }
}

class _MethodBadge extends StatelessWidget {
  const _MethodBadge({required this.method});

  final String method;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        method,
        style: TextStyle(
          color: colorScheme.onSecondaryContainer,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.statusCode,
    required this.hasError,
  });

  final int? statusCode;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor =
        hasError ? colorScheme.errorContainer : colorScheme.primaryContainer;
    final foregroundColor = hasError
        ? colorScheme.onErrorContainer
        : colorScheme.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        statusCode?.toString() ?? (hasError ? 'ERROR' : 'PENDING'),
        style: TextStyle(
          color: foregroundColor,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _InlineScrollableText extends StatelessWidget {
  const _InlineScrollableText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: EnhancedSelectableText(
        text,
        style: const TextStyle(
          fontFamily: 'RobotoMono',
          fontSize: 12,
          height: 1.3,
        ),
      ),
    );
  }
}

class _ScrollableCodeBlock extends StatelessWidget {
  const _ScrollableCodeBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Scrollbar(
                thumbVisibility: true,
                notificationPredicate: (notification) =>
                    notification.depth == 1,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: math.max(0, constraints.maxWidth - 24),
                    ),
                    child: EnhancedSelectableText(
                      text,
                      style: const TextStyle(
                        fontFamily: 'RobotoMono',
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

String? _prettifyPayload(String? text) {
  final trimmed = text?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }

  final bodyIndex = trimmed.indexOf('body: ');
  if (bodyIndex == 0) {
    return _tryPrettyJson(trimmed.substring('body: '.length));
  }

  return trimmed.split('\n').map((line) {
    if (line.startsWith('body: ')) {
      return 'body: ${_tryPrettyJson(line.substring('body: '.length))}';
    }
    if (line.startsWith('headers: ')) {
      return 'headers: ${_tryPrettyJson(line.substring('headers: '.length))}';
    }
    return line;
  }).join('\n');
}

String _tryPrettyJson(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return trimmed;
  }

  if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    try {
      final decoded = jsonDecode(trimmed);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return value;
    }
  }

  return value;
}
