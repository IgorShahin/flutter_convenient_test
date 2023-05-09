import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore: implementation_imports, unnecessary_import
import 'package:flutter_test/src/_matchers_io.dart';
import 'package:path/path.dart' as p;

typedef EnterTextWithoutReplaceLogCallback = void Function(TextEditingValue oldValue, TextEditingValue newValue);

extension ExtWidgetTester on WidgetTester {
  static const _kTag = 'ExtWidgetTester';

  Future<void> enterTextWithoutReplace(Finder finder, String text,
      {EnterTextWithoutReplaceLogCallback? logCallback}) async {
    // reference: [enterText]
    await TestAsyncUtils.guard<void>(() async {
      for (final textFieldInfo in convenientTestGeneralizedEditableTextInfos) {
        final textField = textFieldInfo.findWidget(this, finder);
        if (textField == null) {
          continue; // try next one
        }

        final oldValue = textFieldInfo.extractTextEditingValue(textField);
        // if (oldValue == null) {
        //   throw Exception('To use `enterTextWithoutReplace`, please ensure your TextField has non-null controller');
        // }

        final newValue = _enterTextWithoutReplaceActOnValue(oldValue, text);
        logCallback?.call(oldValue, newValue);

        await textFieldInfo.showKeyboard(this, finder);
        testTextInput.updateEditingValue(newValue);
        await idle();

        return;
      }

      throw Exception(
          'Have tried all infos in convenientTestGeneralizedTextFieldInfos=$convenientTestGeneralizedEditableTextInfos, but none works.');
    });
  }

  // useful in widget-test environment
  // *not* useful integration-test environment, which is what *this* package does
  // https://github.com/fzyzcjy/yplusplus/issues/3793#issuecomment-1120570555
  Future<void> flushRealAsyncTasks([int repeat = 10]) async {
    for (var i = 0; i < repeat; ++i) {
      await runAsync(() => Future<void>.delayed(Duration.zero));
      // only pump (no "pumpAndSettle") here - since sometimes a runAsync task will trigger some background
      // execution that has not finished after delaying zero seconds.
      // see https://github.com/fzyzcjy/yplusplus/issues/4051#issuecomment-1140359618 for more details
      await pump();
    }
    // similar to above, only pump
    await pump();
  }

  // useful for widget tests (not for integration tests)
  Future<void> runAsyncAndPumpUntil(
    FutureOr<bool> Function() canStop, {
    Duration runAsyncDelay = Duration.zero,
    Duration? pumpDuration,
  }) async {
    while (true) {
      // print('runAsyncAndPumpUntil loop');
      if (await canStop()) break;

      // Use delay 0ms instead of 200ms will make it much faster, so make `0ms` the default
      // https://github.com/fzyzcjy/yplusplus/issues/4208
      await runAsync(() => Future<void>.delayed(runAsyncDelay));

      await pump(pumpDuration);
    }
  }

  Future<T> runAsyncEnhanced<T>(Future<T> Function() callback) async {
    if (binding.runningAsyncTasks) {
      // when already have runAsync, should not call it again, otherwise error "Reentrant call to runAsyncEnhanced() denied."
      Log.d(_kTag, 'runAsyncEnhanced skip executing real runAsync since already has pending tasks');
      return callback();
    } else {
      final result = await runAsync(callback);
      // runAsync will eat error https://github.com/fzyzcjy/yplusplus/issues/8054#issuecomment-1503370451
      expect(takeException(), null);
      return result as T;
    }
  }

  // need `runAsync` between pumps, because when running in widget test, the time in pump is fake.
  // If we do not `runAsync` and *really* sleep, things like real network requests may not be able to be finished.
  // https://github.com/fzyzcjy/yplusplus/issues/8477#issuecomment-1528799681
  //
  // implementation ref: `pumpAndSettle`
  Future<void> pumpAndSettleWithRunAsync({
    // #8516
    // p.s. The `pumpAndSettle` timeouts at 10 minutes
    Duration fakeClockTimeout = const Duration(minutes: 1),
    Duration wallClockTimeout = const Duration(minutes: 1),
  }) {
    final DateTime fakeClockEndTime = binding.clock.fromNowBy(fakeClockTimeout);
    final DateTime wallClockEndTime = DateTime.now().add(wallClockTimeout);

    return TestAsyncUtils.guard(() async {
      var count = 0;
      do {
        // https://github.com/fzyzcjy/yplusplus/issues/8545#issuecomment-1530741884
        if (!binding.inTest) {
          Log.w('ConvenientTestInteraction', 'pumpAndSettleWithRunAsync see !inTest thus break');
          break;
        }

        final fakeClockNow = binding.clock.now();
        final wallClockNow = DateTime.now();
        if (fakeClockNow.isAfter(fakeClockEndTime) || wallClockNow.isAfter(wallClockEndTime)) {
          throw FlutterError('pumpAndSettleWithRunAsync timed out '
              '(fakeClockEndTime=$fakeClockEndTime, wallClockEndTime=$wallClockEndTime, '
              'fakeClockNow=$fakeClockNow, wallClockNow=$wallClockNow)');
        }

        if (count > 0 && count % 10 == 0) {
          Log.d('ConvenientTestInteraction', 'pumpAndSettleWithRunAsync has been running for $count cycles');
        }

        await pumpWithRunAsync();
        count++;
      } while (binding.hasScheduledFrame);
    });
  }

  Future<void> pumpWithRunAsync({
    // pumpAndSettle's default value
    Duration pumpDuration = const Duration(milliseconds: 100),
    // https://github.com/fzyzcjy/yplusplus/issues/8481#issuecomment-1529038831
    Duration realDelayDuration = const Duration(milliseconds: 10),
  }) async {
    await binding.pump(pumpDuration);
    await runAsyncEnhanced(() => Future<void>.delayed(realDelayDuration));
  }
}

Future<void> debugWidgetTestSaveScreenshot([Finder? finder, String stem = 'debug_screenshot']) async {
  await TestWidgetsFlutterBinding.instance.runAsync(() async {
    final image = await captureImage((finder ?? find.byType(MaterialApp)).evaluate().single);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    final path = p.join((goldenFileComparator as LocalFileComparator).basedir.path, '$stem.png');
    debugPrint(
        'debugWidgetTestSaveScreenshot save to path=$path image.size=${image.width}x${image.height} byte.length=${bytes.length}');
    File(path).writeAsBytesSync(bytes);
  });
}

const kDefaultConvenientTestGeneralizedEditableTextInfos = <GeneralizedEditableTextInfo>[EditableTextInfo()];

// users can customize this, for example, if they have a custom MyTextField which is similar to TextField
// ignore: avoid-global-state
var convenientTestGeneralizedEditableTextInfos = kDefaultConvenientTestGeneralizedEditableTextInfos;

abstract class GeneralizedEditableTextInfo<T extends Widget> {
  const GeneralizedEditableTextInfo();

  Type get widgetType => T;

  T? findWidget(WidgetTester tester, Finder finder) => tester
      .widgetList<T>(find.descendant(of: finder, matching: find.byType(widgetType), matchRoot: true))
      .singleOrNull;

  TextEditingValue extractTextEditingValue(T widget);

  Future<void> showKeyboard(WidgetTester tester, Finder finder) => tester.showKeyboard(finder);
}

/// Used for [TextField] and [EditableText]
class EditableTextInfo extends GeneralizedEditableTextInfo<EditableText> {
  const EditableTextInfo();

  @override
  TextEditingValue extractTextEditingValue(EditableText widget) => widget.controller.value;

  @override
  String toString() => 'EditableTextInfo{}';
}

// TODO ok?
TextEditingValue _enterTextWithoutReplaceActOnValue(TextEditingValue oldValue, String text) {
  if (!oldValue.selection.isValid) {
    final newText = oldValue.text + text;
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }
  return oldValue.replaced(oldValue.selection, text);
}
