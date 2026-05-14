// ignore_for_file: implementation_imports

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/src/backend/declarer.dart';
import 'package:test_api/src/backend/group.dart';
import 'package:test_api/src/backend/group_entry.dart';
import 'package:test_api/src/backend/test.dart';
import 'package:tuple/tuple.dart';

class SpyDeclarer implements Declarer {
  final Declarer inner;
  final SpyDeclarerGroup info;

  SpyDeclarer(this.inner, this.info);

  static Tuple2<T, SpyDeclarerGroup> withSpy<T>(
    T Function() body, {
    SpyDeclarerGroup? info,
  }) {
    final originalDeclarer = Declarer.current!;
    final spyDeclarer = SpyDeclarer(
      originalDeclarer,
      info ?? SpyDeclarerGroup(name: null),
    );
    final bodyResult = runZoned(
      body,
      zoneValues: {#test.declarer: spyDeclarer},
    );
    return Tuple2(bodyResult, spyDeclarer.info);
  }

  @override
  void addTearDownAll(dynamic Function() callback) =>
      inner.addTearDownAll(callback);

  @override
  Group build() => inner.build();

  @override
  T declare<T>(T Function() body, {Map<Symbol, Object?>? zoneValues}) =>
      runZoned(body, zoneValues: {#test.declarer: this, ...?zoneValues});

  @override
  void setUp(FutureOr<dynamic> Function() callback) => inner.setUp(callback);

  @override
  void setUpAll(
    FutureOr<dynamic> Function() callback, {
    Object? location,
  }) =>
      _invokeDeclarerMember(
        inner.setUpAll,
        positionalArguments: [callback],
        namedArguments: {#location: location},
      );

  @override
  void tearDown(FutureOr<dynamic> Function() callback) =>
      inner.tearDown(callback);

  @override
  void tearDownAll(
    FutureOr<dynamic> Function() callback, {
    Object? location,
  }) =>
      _invokeDeclarerMember(
        inner.tearDownAll,
        positionalArguments: [callback],
        namedArguments: {#location: location},
      );

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
    final innerInfo = SpyDeclarerGroup(name: _prefix(name));
    info.entries.add(innerInfo);

    _invokeDeclarerMember(
      inner.group,
      positionalArguments: [
        name,
        () => SpyDeclarer.withSpy(body, info: innerInfo)
      ],
      namedArguments: {
        #testOn: testOn,
        #timeout: timeout,
        #skip: skip,
        #onPlatform: onPlatform,
        #tags: tags,
        #location: location,
        #retry: retry,
        #solo: solo,
      },
    );
  }

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
    info.entries.add(SpyDeclarerTest(name: _prefix(name)));
    _invokeDeclarerMember(
      inner.test,
      positionalArguments: [name, body],
      namedArguments: {
        #testOn: testOn,
        #timeout: timeout,
        #skip: skip,
        #onPlatform: onPlatform,
        #tags: tags,
        #location: location,
        #retry: retry,
        #solo: solo,
      },
    );
  }

  // ref: [Declarer._prefix]
  /// Returns [name] prefixed with this declarer's group name.
  String _prefix(String name) =>
      info.name == null ? name : '${info.name} $name';
}

/// 类比[GroupEntry]
abstract class SpyDeclarerGroupEntry {
  final String? name;

  const SpyDeclarerGroupEntry({required this.name});
}

/// 类比[Group]
class SpyDeclarerGroup extends SpyDeclarerGroupEntry {
  final entries = <SpyDeclarerGroupEntry>[];

  SpyDeclarerGroup({required super.name});

  @override
  String toString() => 'SpyDeclarerGroup{name: $name, entries: $entries}';
}

/// 类比[Test]
class SpyDeclarerTest extends SpyDeclarerGroupEntry {
  const SpyDeclarerTest({required super.name});

  @override
  String toString() => 'SpyDeclarerTest{name: $name}';
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
