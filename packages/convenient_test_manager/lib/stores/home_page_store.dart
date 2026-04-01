import 'package:convenient_test_common/convenient_test_common.dart';
import 'package:mobx/mobx.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

part 'home_page_store.g.dart';

class HomePageStore = _HomePageStore with _$HomePageStore;

abstract class _HomePageStore with Store {
  @observable
  bool displayLoadedReportMode = false;

  @observable
  var activeSecondaryPanelTab = HomePageSecondaryPanelTab.screenshot;

  @observable
  var expandSecondaryPanel = true;

  final itemScrollController = ItemScrollController();
  final itemPositionsListener = ItemPositionsListener.create();

  /// key: testId; value: ListView index of *first* log entry of that test
  final rdtListViewIndexOfFirstLogEntryOfTestIdMap = ObservableMap<int, int>();

  final logEntryExpandErrorInfoMap =
      ObservableDefaultMap<int, bool>(createDefaultValue: (_) => false);

  final allureStepExpandMap =
      ObservableDefaultMap<String, bool>(createDefaultValue: (_) => true);

  final allurePublishUiState = Observable(AllurePublishUiState.idle);
}

enum HomePageSecondaryPanelTab {
  screenshot,
  requests,
  video,
  rawLog,
  none,
}

enum AllurePublishUiState {
  idle,
  publishing,
  published,
  timeout,
  failed,
}

extension ExtHomePageSecondaryPanelTab on HomePageSecondaryPanelTab {
  String get title {
    switch (this) {
      case HomePageSecondaryPanelTab.screenshot:
        return 'Screenshots';
      case HomePageSecondaryPanelTab.requests:
        return 'Chuck';
      case HomePageSecondaryPanelTab.video:
        return 'Videos';
      case HomePageSecondaryPanelTab.rawLog:
        return 'Raw Logs';
      case HomePageSecondaryPanelTab.none:
        return 'None';
    }
  }
}
