import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/version_vector.dart';

void main() {
  test('missing devices read as 0; includes', () {
    final v = VersionVector({'a': 3});
    expect(v['a'], 3);
    expect(v['b'], 0);
    expect(v.includes('a', 3), isTrue);
    expect(v.includes('a', 4), isFalse);
    expect(v.includes('b', 0), isTrue);
  });

  test('merge is pointwise max, commutative and idempotent', () {
    final a = VersionVector({'a': 3, 'b': 1});
    final b = VersionVector({'b': 5, 'c': 2});
    final m = a.merge(b);
    expect(m.entries, {'a': 3, 'b': 5, 'c': 2});
    expect(b.merge(a), m);
    expect(m.merge(m), m);
    expect(m.merge(a), m);
  });

  test('dominates', () {
    final a = VersionVector({'a': 3, 'b': 1});
    expect(a.dominates(VersionVector({'a': 2})), isTrue);
    expect(a.dominates(VersionVector.empty), isTrue);
    expect(a.dominates(VersionVector({'c': 1})), isFalse);
    expect(VersionVector.empty.dominates(a), isFalse);
    expect(a.dominates(a), isTrue);
  });

  test('equality ignores zero entries', () {
    expect(VersionVector({'a': 1, 'b': 0}), VersionVector({'a': 1}));
    expect(VersionVector({'a': 1, 'b': 0}).hashCode,
        VersionVector({'a': 1}).hashCode);
    expect(VersionVector({'z': 0}), VersionVector.empty);
    expect(VersionVector({'a': 1}) == VersionVector({'a': 2}), isFalse);
    expect(VersionVector({'a': 1}).entries.containsKey('b'), isFalse);
  });

  test('withEntry and immutability', () {
    final a = VersionVector({'a': 1});
    final b = a.withEntry('b', 4);
    expect(a.entries, {'a': 1});
    expect(b.entries, {'a': 1, 'b': 4});
    expect(() => b.entries['c'] = 1, throwsUnsupportedError);
  });

  test('JSON round trip', () {
    final v = VersionVector({'a': 3, 'b': 7});
    final json = jsonDecode(jsonEncode(v.toJson())) as Map<String, Object?>;
    expect(json, {'a': 3, 'b': 7});
    expect(VersionVector.fromJson(json), v);
    expect(() => VersionVector.fromJson({'a': 'x'}), throwsA(isA<TypeError>()));
  });
}
