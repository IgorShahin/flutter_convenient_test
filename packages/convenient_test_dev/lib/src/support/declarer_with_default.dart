import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:test_api/src/backend/declarer.dart';

class DeclarerWithDefault extends Declarer {
  // NOTE use this for flaky test retrying, see #16
  final int? defaultRetry;

  DeclarerWithDefault({required this.defaultRetry});

  @override
  void test(
    String name,
    FutureOr<dynamic> Function() body, {
    Object? location,
    String? testOn,
    Timeout? timeout,
    Object? skip,
    Map<String, dynamic>? onPlatform,
    Object? tags,
    int? retry,
    bool solo = false,
  }) {
    _invokeDeclarerMember(
      super.test,
      positionalArguments: [name, body],
      namedArguments: {
        #testOn: testOn,
        #timeout: timeout,
        #skip: skip,
        #onPlatform: onPlatform,
        #tags: tags,
        #location: location,
        // NOTE use this for flaky test retrying, see #16
        #retry: retry ?? defaultRetry,
        #solo: solo,
      },
    );
  }

  @override
  void group(
    String name,
    void Function() body, {
    Object? location,
    String? testOn,
    Timeout? timeout,
    Object? skip,
    Map<String, dynamic>? onPlatform,
    Object? tags,
    int? retry,
    bool solo = false,
  }) {
    _invokeDeclarerMember(
      super.group,
      positionalArguments: [name, body],
      namedArguments: {
        #testOn: testOn,
        #timeout: timeout,
        #skip: skip,
        #onPlatform: onPlatform,
        #tags: tags,
        #location: location,
        // NOTE use this for flaky test retrying, see #16
        #retry: retry ?? defaultRetry,
        #solo: solo,
      },
    );
  }
}

void _invokeDeclarerMember(
  Function target, {
  required List<Object?> positionalArguments,
  required Map<Symbol, Object?> namedArguments,
}) {
  final cleanedNamedArguments = <Symbol, Object?>{
    for (final entry in namedArguments.entries)
      if (entry.value != null || entry.key == #solo) entry.key: entry.value,
  };
  try {
    Function.apply(target, positionalArguments, cleanedNamedArguments);
  } catch (error) {
    if (error is! NoSuchMethodError) rethrow;
    final withoutLocation = Map<Symbol, Object?>.from(cleanedNamedArguments)
      ..remove(#location);
    Function.apply(target, positionalArguments, withoutLocation);
  }
}
