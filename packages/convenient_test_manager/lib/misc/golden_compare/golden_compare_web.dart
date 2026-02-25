import 'package:flutter_test/flutter_test.dart';

Future<ComparisonResult> compareGoldenBytes(
  List<int> originalContent,
  List<int> newContent,
) =>
    GoldenFileComparator.compareLists(originalContent, newContent);
