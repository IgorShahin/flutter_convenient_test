import 'package:convenient_test_dev/convenient_test_dev.dart';
import 'package:convenient_test_dev/src/support/get_it.dart';
import 'package:convenient_test_dev/src/support/static_config.dart';

extension ConvenientTestMisc on ConvenientTest {
  String get appCodeDir => StaticConfig.kAppCodeDir;

  /// Restarts the app under test by invoking [ConvenientTestSlot.appMain].
  ///
  /// This is an in-app restart helper (not VM hot restart).
  Future<void> restartApp({
    bool settle = true,
    String stepTitle = 'APP RESTART',
  }) async {
    convenientTestLog(stepTitle, '');
    await tester.runAsync(() async {
      await myGetIt.get<ConvenientTestSlot>().appMain(
            AppMainExecuteMode.integrationTest,
          );
    });
    await tester.pumpAndMaybeSettleWithRunAsync(settle: settle);
  }
}
