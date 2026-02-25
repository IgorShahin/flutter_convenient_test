import 'package:convenient_test_manager/components/home_page/command_info_panel.dart';
import 'package:convenient_test_manager/components/home_page/header/header_panel.dart';
import 'package:convenient_test_manager/components/home_page/secondary_panel.dart';
import 'package:convenient_test_manager/services/misc_flutter_service.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager_dart/services/vm_service_wrapper_service.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:get_it/get_it.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const kRouteName = '/home';

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: _Body(),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  static const _kSplitterWidth = 10.0;
  static const _kDefaultLeftPanelFraction = 0.5;
  static const _kMinPanelWidth = 220.0;
  double _leftPanelFraction = _kDefaultLeftPanelFraction;

  @override
  Widget build(BuildContext context) {
    return Observer(builder: (_) {
      return Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const HomePageHeaderPanel(),
              Divider(
                  height: 1,
                  thickness: 1,
                  color: Theme.of(context).colorScheme.outline),
              Expanded(
                child: _buildBody(context),
              ),
              // temporarily disable because of #25
              // const HomePageInputKeyHandler(),
            ],
          ),
          _buildHotRestartHint(context),
        ],
      );
    });
  }

  Widget _buildBody(BuildContext context) {
    final vmServiceWrapperService = GetIt.I.get<VmServiceWrapperService>();
    final suiteInfoStore = GetIt.I.get<SuiteInfoStore>();
    final workerSuperRunStore = GetIt.I.get<WorkerSuperRunStore>();
    final homePageStore = GetIt.I.get<HomePageStore>();

    if (!homePageStore.displayLoadedReportMode &&
        !vmServiceWrapperService.connected) {
      return _buildFullscreenHint(
        context: context,
        onTap: vmServiceWrapperService.connect,
        tapHint: const Text('Tap here to reconnect'),
        child: const Text('VMService not connected. '
            'This may be because the Worker is not running, or network has problem. '),
      );
    }

    if (!homePageStore.displayLoadedReportMode &&
        suiteInfoStore.suiteInfo == null) {
      return _buildFullscreenHint(
        context: context,
        onTap: () => GetIt.I.get<MiscFlutterService>().reloadInfo(),
        tapHint: const Text('Tap here to reload information'),
        child: const Text(
          'No tests found. '
          'This may be because the information is not loaded.',
        ),
      );
    }

    if (workerSuperRunStore.currSuperRunController.isInteractiveApp) {
      return _buildFullscreenHint(
        context: context,
        onTap: () => GetIt.I.get<MiscFlutterService>().reloadInfo(),
        tapHint: const Text('Tap here to end the mode and reload information'),
        child: const Text(
          'The app in your Android/iOS device is running in "app mode" instead of "integration test mode", '
          'i.e. it is fully interactive and you can play with it.',
        ),
      );
    }

    return Stack(
      children: [
        LayoutBuilder(builder: (context, constraints) {
          if (!homePageStore.expandSecondaryPanel) {
            return const Row(
              children: [
                Expanded(child: HomePageCommandInfoPanel()),
              ],
            );
          }

          final totalWidth = constraints.maxWidth;
          final available =
              (totalWidth - _kSplitterWidth).clamp(1.0, 1000000.0);
          final minFraction = (_kMinPanelWidth / available).clamp(0.15, 0.45);
          final maxFraction = 1 - minFraction;
          final clampedFraction = _leftPanelFraction.clamp(
            minFraction,
            maxFraction,
          );
          _leftPanelFraction = clampedFraction;

          final leftWidth = available * clampedFraction;
          final rightWidth = available - leftWidth;

          return Row(
            children: [
              SizedBox(
                width: leftWidth,
                child: const HomePageCommandInfoPanel(),
              ),
              _buildSplitter(
                context: context,
                totalWidth: totalWidth,
                minFraction: minFraction,
                maxFraction: maxFraction,
              ),
              SizedBox(
                width: rightWidth,
                child: const HomePageSecondaryPanel(),
              ),
            ],
          );
        }),
        if (!homePageStore.expandSecondaryPanel)
          Positioned(
            right: 4,
            top: 4,
            child: SizedBox(
              height: 32,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: OutlinedButton(
                  onPressed: () => homePageStore.expandSecondaryPanel = true,
                  child: const Text('Expand secondary panel'),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSplitter({
    required BuildContext context,
    required double totalWidth,
    required double minFraction,
    required double maxFraction,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () {
          setState(() => _leftPanelFraction = _kDefaultLeftPanelFraction);
        },
        onHorizontalDragUpdate: (details) {
          if (totalWidth <= 0) return;
          final next =
              _leftPanelFraction + details.delta.dx / totalWidth;
          setState(() {
            _leftPanelFraction = next.clamp(minFraction, maxFraction);
          });
        },
        child: SizedBox(
          width: _kSplitterWidth,
          child: Center(
            child: Container(
              width: 1,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFullscreenHint({
    required VoidCallback onTap,
    required Widget tapHint,
    required Widget child,
    required BuildContext context,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DefaultTextStyle(
                style: TextStyle(
                    fontSize: 15,
                    height: 1.8,
                    color: Theme.of(context).colorScheme.onSurface),
                child: child,
              ),
              const SizedBox(height: 20),
              TextButton(
                onPressed: onTap,
                child: tapHint,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHotRestartHint(BuildContext context) {
    final vmServiceWrapperService = GetIt.I.get<VmServiceWrapperService>();

    return Positioned(
      top: 48,
      left: 0,
      right: 0,
      child: Center(
        child: Observer(
          builder: (_) => vmServiceWrapperService.hotRestartActing
              ? Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'Worker Restarting...',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white,
                      // fontWeight: FontWeight.w600,
                      height: 1.05,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
