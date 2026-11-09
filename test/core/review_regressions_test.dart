// Regression tests for bugs found in the WP-A review. Each test failed
// before its fix.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/csv_export.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/split.dart';

import 'csv_export_test.dart' show parseCsv;
import 'helpers.dart';

const g = 'g1';

void main() {
  late FakeDevice alex;

  setUp(() {
    FakeDevice.wallMs = kBaseMs;
    alex = FakeDevice('dev-alex');
  });

  List<Operation> base() => [
    alex.createGroup(g),
    alex.addMember(g, 'a', 'Alex', claimedBy: alex.deviceId),
    alex.addMember(g, 'b', 'Bob'),
    alex.addMember(g, 'c', 'Cat'),
  ];

  group('reducer', () {
    test('two ops with the same HLC converge whatever the arrival order', () {
      // A buggy or hostile device can reuse an HLC. Rule 4 must still give
      // every replica the same winner, or replicas diverge for good.
      final ops = base();
      final e = alex.addExpense(
        g,
        'e1',
        money: equalBlock(900, 'a', ['a', 'b', 'c']),
      );
      final hlc = alex.clock.tick();
      final x = alex.op(g, EntityType.expense, 'e1', OpKind.update, {
        ExpenseFields.description: 'X',
      }, hlc: hlc);
      final y = alex.op(g, EntityType.expense, 'e1', OpKind.update, {
        ExpenseFields.description: 'Y',
      }, hlc: hlc);
      final r1 = reduce([...ops, e, x, y]);
      final r2 = reduce([...ops, e, y, x]);
      expect(r1.state.toCanonicalJson(), r2.state.toCanonicalJson());
      expect(
        r1.state.expense('e1')!.description,
        r2.state.expense('e1')!.description,
      );
    });

    test(
      'a money block whose sums only match through int overflow is hidden',
      () {
        // 4 * 2^62 + 5 wraps to 5 in 64-bit ints, so isConsistent alone
        // accepts it, and every member would show an absurd balance.
        const big = 1 << 62;
        final hostile = MoneyBlock(
          total: 5,
          currency: 'GBP',
          paidBy: SplitSpec(SplitMethod.exact, {'a': 5}),
          owedBy: SplitSpec(SplitMethod.exact, {'a': 5}),
          paid: {'a': big, 'b': big, 'c': big, 'd': big + 5},
          owed: {'a': 5},
        );
        final r = reduce([...base(), alex.addExpense(g, 'e1', money: hostile)]);
        final gs = r.state.groups[g]!;
        expect(gs.expenses.containsKey('e1'), isFalse);
        expect(BalanceCalculator.groupNets(gs), isEmpty);
      },
    );

    test('a money block above Money.maxMinor is hidden', () {
      final huge = rawBlock(
        {'a': Money.maxMinor + 1},
        {'b': Money.maxMinor + 1},
      );
      final r = reduce([...base(), alex.addExpense(g, 'e1', money: huge)]);
      expect(r.state.groups[g]!.expenses.containsKey('e1'), isFalse);
    });
  });

  group('splits', () {
    test('check never throws, even for oversize shares', () {
      final spec = SplitSpec(SplitMethod.shares, {'a': 1 << 40, 'b': 1});
      expect(
        () => SplitCalculator.check(Money.maxMinor, spec),
        returnsNormally,
      );
    });

    test('allocate stays exact when total * weight exceeds 64 bits', () {
      final shares = SplitCalculator.allocate(999999999, {
        'a': 1 << 40,
        'b': 1 << 40,
        'c': 1,
      });
      expect(shares.values.fold(0, (a, b) => a + b), 999999999);
      expect(shares.keys, ['a', 'b']);
      expect((shares['a']! - shares['b']!).abs(), lessThanOrEqualTo(1));
    });

    test(
      'exact values that sum to total only through overflow are rejected',
      () {
        const big = 1 << 62;
        final spec = SplitSpec(SplitMethod.exact, {
          'a': big,
          'b': big,
          'c': big,
          'd': big + 100,
        });
        expect(
          () => SplitCalculator.compute(100, spec),
          throwsA(
            isA<SplitException>().having(
              (e) => e.error,
              'error',
              SplitError.sumMismatch,
            ),
          ),
        );
        expect(SplitCalculator.check(100, spec).error, SplitError.sumMismatch);
      },
    );

    test('huge adjustments never escape as StateError', () {
      const k = 1 << 62;
      final spec = SplitSpec(SplitMethod.adjustment, {
        'a': -k,
        'b': -k,
        'c': -k,
      });
      expect(() => SplitCalculator.check(100, spec), returnsNormally);
      // Mathematically every adjustment cancels: 34/33/33.
      expect(SplitCalculator.compute(100, spec), {'a': 34, 'b': 33, 'c': 33});
      final over = SplitSpec(SplitMethod.adjustment, {'a': k, 'b': k, 'c': 0});
      expect(SplitCalculator.check(100, over).error, SplitError.negativeShare);
    });
  });

  group('csv', () {
    test('a formula-looking currency code is neutralised', () {
      final gs = groupOf(
        [member('a'), member('b')],
        [
          expense(rawBlock({'a': 100}, {'b': 100}, currency: '=HYPERLINK(1)')),
        ],
      );
      final rows = parseCsv(CsvExport.group(gs));
      expect(rows[1][4], "'=HYPERLINK(1)");
    });
  });
  group('hlc', () {
    test('only the canonical encoding parses', () {
      // int.parse accepts a sign, surrounding whitespace, a 0x prefix and
      // upper-case hex, so these decoded to valid clocks although their
      // text sorts differently from Hlc.compareTo (the op log and sync
      // rely on encoded order == compareTo).
      for (final bad in [
        '+00000000000009-0000-dev',
        ' 00000000000009-0000-dev',
        '00000000000009 -0000-dev',
        '0x000000000000f-0000-dev',
        '000000000000001-000B-dev',
        '000000000000001-+00b-dev',
        '000000000000001- 00b-dev',
        '000000000000001-0x0b-dev',
      ]) {
        expect(() => Hlc.parse(bad), throwsFormatException, reason: bad);
      }
      const ok = '000000000000001-000b-dev';
      expect(Hlc.parse(ok).encode(), ok);
    });

    test('an op carrying a non-canonical HLC is rejected as malformed', () {
      final json = alex.createGroup(g).toJson();
      json['hlc'] = '000000000000001-000B-${alex.deviceId}';
      expect(() => Operation.fromJson(json), throwsFormatException);
    });
  });
}
