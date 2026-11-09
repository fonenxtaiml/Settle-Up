import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';

Transfer _t(String from, String to, int amount) =>
    Transfer(from: from, to: to, amount: amount, currency: 'GBP');

void main() {
  group('SPEC 6.4 vectors', () {
    test('one creditor, two debtors', () {
      expect(DebtSimplifier.simplify({'a': 50, 'b': -30, 'c': -20}, 'GBP'),
          [_t('b', 'a', 30), _t('c', 'a', 20)]);
    });

    test('chain collapses', () {
      expect(DebtSimplifier.simplify({'A': -10, 'B': 0, 'C': 10}, 'GBP'),
          [_t('A', 'C', 10)]);
    });

    test('ties by id ascending', () {
      expect(
          DebtSimplifier.simplify(
              {'d': -10, 'c': -10, 'b': 10, 'a': 10}, 'GBP'),
          [_t('c', 'a', 10), _t('d', 'b', 10)]);
    });

    test('empty', () {
      expect(DebtSimplifier.simplify({}, 'GBP'), isEmpty);
      expect(DebtSimplifier.simplify({'a': 0, 'b': 0}, 'GBP'), isEmpty);
    });
  });

  test('nets that do not sum to zero throw ArgumentError', () {
    expect(() => DebtSimplifier.simplify({'a': 10, 'b': -9}, 'GBP'),
        throwsArgumentError);
  });

  test('carries the currency', () {
    expect(DebtSimplifier.simplify({'a': 5, 'b': -5}, 'JPY').single.currency,
        'JPY');
  });

  test('larger amounts are matched first', () {
    expect(
        DebtSimplifier.simplify(
            {'a': 100, 'b': 20, 'c': -70, 'd': -50}, 'GBP'),
        [_t('c', 'a', 70), _t('d', 'a', 30), _t('d', 'b', 20)]);
  });

  test('property: 2,000 random net sets of 2-15 members', () {
    final rnd = math.Random(1109);
    for (var i = 0; i < 2000; i++) {
      final n = 2 + rnd.nextInt(14);
      final ids = [for (var k = 0; k < n; k++) 'm${rnd.nextInt(1 << 20)}-$k'];
      final nets = <String, int>{};
      var sum = 0;
      for (var k = 0; k < n - 1; k++) {
        final v = switch (rnd.nextInt(4)) {
          0 => 0,
          1 => rnd.nextInt(10) - 5,
          2 => rnd.nextInt(2000000) - 1000000,
          _ => (rnd.nextInt(5) - 2) * 1000, // many equal amounts (ties)
        };
        nets[ids[k]] = v;
        sum += v;
      }
      nets[ids[n - 1]] = -sum;

      final out = DebtSimplifier.simplify(nets, 'GBP');
      final nonZero = nets.values.where((v) => v != 0).length;
      expect(out.length, lessThanOrEqualTo(math.max(0, nonZero - 1)));
      expect(out.length, lessThanOrEqualTo(n - 1));

      final left = Map<String, int>.of(nets);
      for (final t in out) {
        expect(t.amount, greaterThan(0));
        expect(nets[t.from]!, lessThan(0), reason: 'only debtors pay');
        expect(nets[t.to]!, greaterThan(0), reason: 'only creditors receive');
        left[t.from] = left[t.from]! + t.amount;
        left[t.to] = left[t.to]! - t.amount;
      }
      expect(left.values.every((v) => v == 0), isTrue, reason: '$nets');

      // Identical across runs and independent of map insertion order.
      final keys = nets.keys.toList()..shuffle(rnd);
      final again =
          DebtSimplifier.simplify({for (final k in keys) k: nets[k]!}, 'GBP');
      expect(again, out);
    }
  });
}
