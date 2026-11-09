// Regression tests for bugs found in the WP-A review. Each test failed
// before its fix.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/core/ops.dart';

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
}
