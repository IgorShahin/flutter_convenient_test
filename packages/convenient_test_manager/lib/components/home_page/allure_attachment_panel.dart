import 'package:convenient_test_manager/components/misc/enhanced_selectable_text.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager_dart/stores/allure_custom_step_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:get_it/get_it.dart';

class HomePageAllureAttachmentPanel extends StatelessWidget {
  const HomePageAllureAttachmentPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final homePageStore = GetIt.I.get<HomePageStore>();
    final customStepStore = GetIt.I.get<AllureCustomStepStore>();

    return Observer(
      builder: (_) {
        final stepId = homePageStore.highlightAllureStepId;
        if (homePageStore.allureAttachmentPreviewLoading) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(height: 12),
                Text('Loading attachments...'),
              ],
            ),
          );
        }
        if (stepId == null) {
          return const Center(
            child: Text('Hover a step with attachments to preview them'),
          );
        }

        final step = customStepStore.stepById(stepId);
        if (step == null || step.attachments.isEmpty) {
          return const Center(
            child: Text('No attachments for chosen step'),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: step.attachments.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (_, index) {
            final attachment = step.attachments[index];
            return _AttachmentCard(attachment: attachment);
          },
        );
      },
    );
  }
}

class _AttachmentCard extends StatelessWidget {
  final AllureCustomStepAttachment attachment;

  const _AttachmentCard({
    required this.attachment,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: ElevationOverlay.applySurfaceTint(
          colorScheme.surface,
          colorScheme.surfaceTint,
          1,
        ),
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    attachment.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  attachment.kind.toUpperCase(),
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: EnhancedSelectableText(
                attachment.content,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  fontFamily: 'RobotoMono',
                ),
                enableCopyAllButton: true,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
