import 'package:convenient_test_manager/misc/golden_compare/golden_compare_io.dart'
    if (dart.library.html)
        'package:convenient_test_manager/misc/golden_compare/golden_compare_web.dart'
    as impl;
import 'package:flutter_test/flutter_test.dart';

Future<ComparisonResult> compareGoldenBytes(
  List<int> originalContent,
  List<int> newContent,
) =>
    impl.compareGoldenBytes(originalContent, newContent);
