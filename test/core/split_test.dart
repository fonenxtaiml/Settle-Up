import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/core/split.dart';

Matcher _splitError(SplitError e) =>
    throwsA(isA<SplitException>().having((x) => x.error, 'error', e));

int _sum(Map<String, int> m) => m.values.fold(0, (a, b) => a + b);

Map<String, int> _shuffled(Map<String, int> m, math.Random rnd) {
  final keys = m.keys.toList()..shuffle(rnd);
  return {for (final k in keys) k: m[k]!};
}

void main() {
  group('SPEC 6.1 vectors', () {
    test('1000 equal a,b,c -> 334/333/333', () {
      expect(SplitCalculator.compute(1000, SplitSpec.equal(['a', 'b', 'c'])),
          {'a': 334, 'b': 333, 'c': 333});
    });

    test('100 equal with shuffled insertion order -> a gets the extra', () {
      expect(SplitCalculator.compute(100, SplitSpec.equal(['c', 'a', 'b'])),
          {'a': 34, 'b': 33, 'c': 33});
    });

    test('1000 percent 3333/3333/3334', () {
      expect(
          SplitCalculator.compute(1000,
              const SplitSpec(SplitMethod.percent, {'a': 3333, 'b': 3333, 'c': 3334})),
          {'a': 333, 'b': 333, 'c': 334});
    });

    test('1000 shares a 2, b 1', () {
      expect(
          SplitCalculator.compute(
              1000, const SplitSpec(SplitMethod.shares, {'a': 2, 'b': 1})),
          {'a': 667, 'b': 333});
    });

    test('6000 adjustment a +1000', () {
      expect(
          SplitCalculator.compute(6000,
              const SplitSpec(SplitMethod.adjustment, {'a': 1000, 'b': 0, 'c': 0})),
          {'a': 2667, 'b': 1667, 'c': 1666});
    });

    test('6000 exact under-assigned -> sumMismatch, remaining 450', () {
      const spec =
          SplitSpec(SplitMethod.exact, {'a': 2000, 'b': 2000, 'c': 1550});
      expect(() => SplitCalculator.compute(6000, spec),
          _splitError(SplitError.sumMismatch));
      final check = SplitCalculator.check(6000, spec);
      expect(check.error, SplitError.sumMismatch);
      expect(check.remainingUnits, 450);
      expect(check.targetUnits, 6000);
      expect(check.assignedUnits, 5550);
      expect(check.isValid, isFalse);
      expect(check.shares, isNull);
    });

    test('6000 exact over-assigned -> sumMismatch, remaining -500', () {
      const spec =
          SplitSpec(SplitMethod.exact, {'a': 2000, 'b': 2000, 'c': 2500});
      expect(() => SplitCalculator.compute(6000, spec),
          _splitError(SplitError.sumMismatch));
      expect(SplitCalculator.check(6000, spec).remainingUnits, -500);
    });

    test('1 equal a,b,c -> only a', () {
      expect(SplitCalculator.compute(1, SplitSpec.equal(['a', 'b', 'c'])),
          {'a': 1});
    });

    test('500 JPY equal a,b,c -> 167/167/166', () {
      final block = SplitCalculator.buildMoneyBlock(
        total: 500,
        currency: 'JPY',
        paidBy: SplitSpec.single('a', 500),
        owedBy: SplitSpec.equal(['a', 'b', 'c']),
      );
      expect(block.owed, {'a': 167, 'b': 167, 'c': 166});
      expect(block.isConsistent, isTrue);
    });

    test('6000 adjustment a -7000 -> negativeShare', () {
      expect(
          () => SplitCalculator.compute(6000,
              const SplitSpec(SplitMethod.adjustment, {'a': -7000, 'b': 0})),
          _splitError(SplitError.negativeShare));
    });
  });

  group('validation', () {
    test('nonPositiveTotal', () {
      for (final t in [0, -1, Money.maxMinor + 1]) {
        expect(() => SplitCalculator.compute(t, SplitSpec.equal(['a'])),
            _splitError(SplitError.nonPositiveTotal));
      }
      expect(SplitCalculator.compute(Money.maxMinor, SplitSpec.equal(['a'])),
          {'a': Money.maxMinor});
    });

    test('noParticipants', () {
      for (final m in [
        SplitMethod.equal,
        SplitMethod.exact,
        SplitMethod.percent,
        SplitMethod.adjustment,
      ]) {
        expect(() => SplitCalculator.compute(100, SplitSpec(m, const {})),
            _splitError(SplitError.noParticipants),
            reason: m.name);
      }
    });

    test('exact: negative entries and zero entries', () {
      expect(
          () => SplitCalculator.compute(
              100, const SplitSpec(SplitMethod.exact, {'a': -50, 'b': 150})),
          _splitError(SplitError.negativeShare));
      expect(
          SplitCalculator.compute(
              100, const SplitSpec(SplitMethod.exact, {'a': 0, 'b': 100})),
          {'b': 100});
    });

    test('percent must sum to 10000 and be non-negative', () {
      expect(
          () => SplitCalculator.compute(
              100, const SplitSpec(SplitMethod.percent, {'a': 5000, 'b': 4999})),
          _splitError(SplitError.percentNot100));
      expect(
          () => SplitCalculator.compute(100,
              const SplitSpec(SplitMethod.percent, {'a': -100, 'b': 10100})),
          _splitError(SplitError.negativeShare));
      expect(
          SplitCalculator.compute(
              100, const SplitSpec(SplitMethod.percent, {'a': 10000, 'b': 0})),
          {'a': 100});
    });

    test('shares: weight < 1 or empty -> zeroWeight', () {
      expect(
          () => SplitCalculator.compute(
              100, const SplitSpec(SplitMethod.shares, {'a': 0, 'b': 1})),
          _splitError(SplitError.zeroWeight));
      expect(
          () => SplitCalculator.compute(
              100, const SplitSpec(SplitMethod.shares, {'a': -1, 'b': 3})),
          _splitError(SplitError.zeroWeight));
      expect(
          () => SplitCalculator.compute(
              100, const SplitSpec(SplitMethod.shares, {})),
          _splitError(SplitError.zeroWeight));
    });

    test('adjustment: negative final share', () {
      expect(
          () => SplitCalculator.compute(100,
              const SplitSpec(SplitMethod.adjustment, {'a': -120, 'b': 0})),
          _splitError(SplitError.negativeShare));
      // Negative adjustments that keep everyone >= 0 are fine.
      expect(
          SplitCalculator.compute(100,
              const SplitSpec(SplitMethod.adjustment, {'a': -10, 'b': 0})),
          {'a': 45, 'b': 55});
      // The whole amount as an adjustment: rest is 0.
      expect(
          SplitCalculator.compute(100,
              const SplitSpec(SplitMethod.adjustment, {'a': 100, 'b': 0})),
          {'a': 100});
    });
  });

  group('allocate', () {
    test('largest remainder, ties by id ascending', () {
      expect(SplitCalculator.allocate(10, {'b': 1, 'a': 1, 'c': 1}),
          {'a': 4, 'b': 3, 'c': 3});
      expect(SplitCalculator.allocate(2, {'c': 1, 'b': 1, 'a': 1}),
          {'a': 1, 'b': 1});
      // b's remainder (2/3) beats a's (1/3).
      expect(SplitCalculator.allocate(1, {'a': 1, 'b': 2}), {'b': 1});
    });

    test('zero weights get nothing; zero total gives empty', () {
      expect(SplitCalculator.allocate(7, {'a': 0, 'b': 1}), {'b': 7});
      expect(SplitCalculator.allocate(0, {'a': 1, 'b': 1}), isEmpty);
    });

    test('errors', () {
      expect(() => SplitCalculator.allocate(5, {'a': 0}),
          _splitError(SplitError.zeroWeight));
      expect(() => SplitCalculator.allocate(5, {}),
          _splitError(SplitError.zeroWeight));
      expect(() => SplitCalculator.allocate(5, {'a': -1, 'b': 2}),
          _splitError(SplitError.negativeShare));
      expect(() => SplitCalculator.allocate(-5, {'a': 1}), throwsArgumentError);
    });

    test('max total with max percent weights stays exact', () {
      final r = SplitCalculator.allocate(
          Money.maxMinor, {'a': 3333, 'b': 3333, 'c': 3334});
      expect(_sum(r), Money.maxMinor);
    });
  });

  group('check', () {
    test('never throws, reports units per method', () {
      final eq = SplitCalculator.check(100, SplitSpec.equal(['a', 'b']));
      expect(eq.isValid, isTrue);
      expect(eq.targetUnits, 2);
      expect(eq.remainingUnits, 0);
      expect(eq.shares, {'a': 50, 'b': 50});

      final pct = SplitCalculator.check(
          100, const SplitSpec(SplitMethod.percent, {'a': 2500}));
      expect(pct.targetUnits, 10000);
      expect(pct.assignedUnits, 2500);
      expect(pct.remainingUnits, 7500);
      expect(pct.error, SplitError.percentNot100);

      final sh = SplitCalculator.check(
          90, const SplitSpec(SplitMethod.shares, {'a': 2, 'b': 1}));
      expect(sh.targetUnits, 3);
      expect(sh.assignedUnits, 3);
      expect(sh.shares, {'a': 60, 'b': 30});

      final adj = SplitCalculator.check(
          100, const SplitSpec(SplitMethod.adjustment, {'a': 30, 'b': 0}));
      expect(adj.targetUnits, 100);
      expect(adj.assignedUnits, 30);
      expect(adj.shares, {'a': 65, 'b': 35});

      final bad = SplitCalculator.check(0, SplitSpec.equal(['a']));
      expect(bad.error, SplitError.nonPositiveTotal);
      expect(SplitCalculator.check(100, const SplitSpec(SplitMethod.equal, {}))
          .error, SplitError.noParticipants);
    });

    test('shares are unmodifiable', () {
      final c = SplitCalculator.check(100, SplitSpec.equal(['a']));
      expect(() => c.shares!['x'] = 1, throwsUnsupportedError);
    });
  });

  group('money blocks', () {
    test('buildMoneyBlock with multiple payers', () {
      final b = SplitCalculator.buildMoneyBlock(
        total: 1001,
        currency: 'GBP',
        paidBy: SplitSpec.equal(['b', 'a']),
        owedBy: const SplitSpec(SplitMethod.shares, {'a': 1, 'b': 1, 'c': 2}),
      );
      expect(b.paid, {'a': 501, 'b': 500});
      expect(b.owed, {'a': 250, 'b': 250, 'c': 501});
      expect(b.isConsistent, isTrue);
      expect(b.total, 1001);
      expect(b.currency, 'GBP');
      expect(b.paidBy.method, SplitMethod.equal);
      final back = MoneyBlock.fromJson(b.toJson());
      expect(back.paid, b.paid);
      expect(back.owed, b.owed);
      expect(back.paidBy, b.paidBy);
      expect(back.owedBy, b.owedBy);
    });

    test('buildMoneyBlock propagates split errors from either side', () {
      expect(
          () => SplitCalculator.buildMoneyBlock(
                total: 100,
                currency: 'GBP',
                paidBy: const SplitSpec(SplitMethod.exact, {'a': 90}),
                owedBy: SplitSpec.equal(['a', 'b']),
              ),
          _splitError(SplitError.sumMismatch));
      expect(
          () => SplitCalculator.buildMoneyBlock(
                total: 100,
                currency: 'GBP',
                paidBy: SplitSpec.single('a', 100),
                owedBy: const SplitSpec(SplitMethod.percent, {'a': 1}),
              ),
          _splitError(SplitError.percentNot100));
    });

    test('paymentBlock', () {
      final p = SplitCalculator.paymentBlock(
          from: 'b', to: 'a', amount: 840, currency: 'GBP');
      expect(p.paid, {'b': 840});
      expect(p.owed, {'a': 840});
      expect(p.total, 840);
      expect(p.isConsistent, isTrue);
      expect(
          () => SplitCalculator.paymentBlock(
              from: 'b', to: 'a', amount: 0, currency: 'GBP'),
          _splitError(SplitError.nonPositiveTotal));
    });
  });

  group('properties', () {
    test('5,000 random specs: sum == total, deterministic under shuffling',
        () {
      final rnd = math.Random(20261109);
      const ids = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l'];
      var valid = 0;
      for (var i = 0; i < 5000; i++) {
        final total = switch (rnd.nextInt(4)) {
          0 => 1 + rnd.nextInt(10),
          1 => 1 + rnd.nextInt(10000),
          2 => 1 + _below(rnd, Money.maxMinor),
          _ => Money.maxMinor,
        };
        final n = 1 + rnd.nextInt(ids.length);
        final members = (List.of(ids)..shuffle(rnd)).take(n).toList();
        final method = SplitMethod.values[rnd.nextInt(SplitMethod.values.length)];
        final Map<String, int> values;
        switch (method) {
          case SplitMethod.equal:
            values = {for (final m in members) m: 1};
          case SplitMethod.exact:
            values = SplitCalculator.allocate(
                total, {for (final m in members) m: 1 + rnd.nextInt(50)});
            for (final m in members) {
              values.putIfAbsent(m, () => 0);
            }
          case SplitMethod.percent:
            values = SplitCalculator.allocate(
                10000, {for (final m in members) m: 1 + rnd.nextInt(50)});
          case SplitMethod.shares:
            values = {for (final m in members) m: 1 + rnd.nextInt(1000)};
          case SplitMethod.adjustment:
            values = {
              for (final m in members)
                m: rnd.nextInt(3) == 0 ? 0 : _below(rnd, total ~/ n + 1) - total ~/ (4 * n),
            };
        }
        final spec = SplitSpec(method, values);
        Map<String, int>? first;
        SplitError? error;
        try {
          first = SplitCalculator.compute(total, spec);
        } on SplitException catch (e) {
          error = e.error;
        }
        if (first != null) {
          valid++;
          expect(_sum(first), total, reason: '$method $values');
          expect(first.values.every((v) => v > 0), isTrue);
          expect(values.keys.toSet().containsAll(first.keys), isTrue);
        } else {
          // Only adjustment specs may be invalid here.
          expect(method, SplitMethod.adjustment);
          expect(error, SplitError.negativeShare);
        }
        for (var s = 0; s < 3; s++) {
          final again = SplitSpec(method, _shuffled(values, rnd));
          if (first == null) {
            expect(() => SplitCalculator.compute(total, again),
                _splitError(error!));
          } else {
            final r = SplitCalculator.compute(total, again);
            expect(r, first);
            expect(r.keys.toList(), first.keys.toList(),
                reason: 'output order is canonical');
          }
        }
        final check = SplitCalculator.check(total, spec);
        expect(check.error, error);
        expect(check.shares, first);
      }
      expect(valid, greaterThan(4000));
    });

    test('equal split shares differ by at most 1 and favour low ids', () {
      final rnd = math.Random(3);
      for (var i = 0; i < 1000; i++) {
        final n = 1 + rnd.nextInt(20);
        final members = [for (var k = 0; k < n; k++) 'm${k.toString().padLeft(2, '0')}'];
        final total = n + rnd.nextInt(100000);
        final r = SplitCalculator.compute(total, SplitSpec.equal(members..shuffle(rnd)));
        final sorted = r.keys.toList()..sort();
        final amounts = [for (final k in sorted) r[k]!];
        expect(amounts.reduce(math.max) - amounts.reduce(math.min),
            lessThanOrEqualTo(1));
        for (var k = 1; k < amounts.length; k++) {
          expect(amounts[k - 1], greaterThanOrEqualTo(amounts[k]));
        }
      }
    });
  });
}

/// A random int in 0..n-1 for any n (Random.nextInt stops at 2^32, below
/// Money.maxMinor).
int _below(math.Random rnd, int n) =>
    math.min(n - 1, (rnd.nextDouble() * n).floor());
