import 'package:convenient_test_manager/components/misc/state_indicator.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager_dart/stores/allure_custom_step_store.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:get_it/get_it.dart';

class HomePageAllureCustomStepWidget extends StatelessWidget {
  final int order;
  final AllureCustomStepNode node;
  final int depth;

  const HomePageAllureCustomStepWidget({
    super.key,
    required this.order,
    required this.node,
    required this.depth,
  });

  @override
  Widget build(BuildContext context) {
    final homePageStore = GetIt.I.get<HomePageStore>();
    return Observer(
      builder: (_) {
        final expanded = homePageStore.allureStepExpandMap[node.id];
        final errorExpanded = homePageStore.allureStepErrorExpandMap[node.id];
        final hasLongError = _hasLongError(node.errorText);
        return Container(
          margin: const EdgeInsets.only(left: 32),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                        if (node.parameters.isNotEmpty) ...[
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
      },
    );
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
