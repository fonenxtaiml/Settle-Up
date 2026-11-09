import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/split.dart';

import 'helpers.dart';

void _expectNetsSumToZero(NetsByCurrency nets) {
  nets.forEach((c, byMember) {
    expect(byMember.values.fold(0, (a, b) => a + b), 0, reason: c);
    expect(byMember.values.every((v) => v != 0), isTrue);
  });
}

/// Applying [transfers] to [nets] must zero every member.
void _expectSettles(NetsByCurrency nets, List<Transfer> transfers) {
  final left = {
    for (final e in nets.entries) e.key: Map<String, int>.of(e.value),
  };
  for (final t in transfers) {
    expect(t.amount, greaterThan(0));
    expect(t.from, isNot(t.to));
    final cur = left.putIfAbsent(t.currency, () => {});
    cur[t.from] = (cur[t.from] ?? 0) + t.amount;
    cur[t.to] = (cur[t.to] ?? 0) - t.amount;
  }
  left.forEach((c, byMember) {
    byMember.forEach((m, v) => expect(v, 0, reason: '$c $m'));
  });
}

void main() {
  final abc = [member('a'), member('b'), member('c')];

  group('groupNets', () {
    test('sums paid - owed per member and currency, sums to zero', () {
      final g = groupOf(abc, [
        expense(equalBlock(9000, 'a', ['a', 'b', 'c'])),
        expense(equalBlock(1000, 'b', ['a', 'b', 'c'])),
        expense(equalBlock(500, 'c', ['a', 'c'], currency: 'EUR')),
      ]);
      final nets = BalanceCalculator.groupNets(g);
      expect(nets, {
        'EUR': {'a': -250, 'c': 250},
        'GBP': {'a': 5666, 'b': -2333, 'c': -3333},
      });
      expect(nets.keys.toList(), ['EUR', 'GBP']);
      _expectNetsSumToZero(nets);
    });

    test('multi-currency kept separate, never converted', () {
      final g = groupOf(abc, [
        expense(equalBlock(1000, 'a', ['a', 'b'])),
        expense(equalBlock(1000, 'b', ['a', 'b'], currency: 'JPY')),
      ]);
      expect(BalanceCalculator.groupNets(g), {
        'GBP': {'a': 500, 'b': -500},
        'JPY': {'a': -500, 'b': 500},
      });
    });

    test('payments count and can settle a currency to nothing', () {
      final g = groupOf(abc, [
        expense(equalBlock(1000, 'a', ['a', 'b'])),
        expense(SplitCalculator.paymentBlock(
            from: 'b', to: 'a', amount: 500, currency: 'GBP'),
            kind: ExpenseKind.payment),
      ]);
      expect(BalanceCalculator.groupNets(g), isEmpty);
      expect(BalanceCalculator.suggestedTransfers(g), isEmpty);
    });

    test('over-payment flips the direction', () {
      final g = groupOf(abc, [
        expense(equalBlock(1000, 'a', ['a', 'b'])),
        expense(SplitCalculator.paymentBlock(
            from: 'b', to: 'a', amount: 800, currency: 'GBP'),
            kind: ExpenseKind.payment),
      ]);
      expect(BalanceCalculator.groupNets(g), {
        'GBP': {'a': -300, 'b': 300},
      });
    });

    test('deleted and inconsistent expenses are excluded', () {
      final g = groupOf(abc, [
        expense(equalBlock(900, 'a', ['a', 'b', 'c'])),
        expense(equalBlock(5000, 'b', ['a', 'b']), deleted: true),
        expense(rawBlock({'c': 100}, {'a': 50})), // owed != paid
        expense(rawBlock({'c': 100}, {'a': 150, 'b': -50})), // negative
      ]);
      expect(g.liveExpenses.length, 1);
      expect(BalanceCalculator.groupNets(g), {
        'GBP': {'a': 600, 'b': -300, 'c': -300},
      });
    });

    test('merged members are attributed to their target', () {
      final g = groupOf([
        ...abc,
        member('b2', mergedInto: 'b'),
      ], [
        expense(equalBlock(900, 'a', ['a', 'b', 'b2'])),
        expense(equalBlock(300, 'b2', ['c'])),
      ]);
      expect(BalanceCalculator.groupNets(g), {
        'GBP': {'a': 600, 'b': -300, 'c': -300},
      });
    });

    test('removed members keep their balances', () {
      final g = groupOf([
        member('a'),
        member('b', removed: true),
      ], [
        expense(equalBlock(1000, 'a', ['a', 'b'])),
      ]);
      expect(g.activeMembers.map((m) => m.id), ['a']);
      expect(BalanceCalculator.groupNets(g), {
        'GBP': {'a': 500, 'b': -500},
      });
      expect(BalanceCalculator.suggestedTransfers(g), [
        const Transfer(from: 'b', to: 'a', amount: 500, currency: 'GBP'),
      ]);
    });

    test('members unknown to the group are still counted', () {
      final g = groupOf([member('a')], [
        expense(equalBlock(1000, 'a', ['a', 'ghost'])),
      ]);
      expect(BalanceCalculator.groupNets(g), {
        'GBP': {'a': 500, 'ghost': -500},
      });
    });
  });

  group('pairwiseDebts (original view)', () {
    test('SPEC 6.3 vector', () {
      final g = groupOf(abc, [
        expense(equalBlock(9000, 'a', ['a', 'b', 'c'])),
        expense(rawBlock({'b': 3000}, {'a': 1500, 'b': 1500})),
      ]);
      expect(BalanceCalculator.pairwiseDebts(g), [
        const Transfer(from: 'b', to: 'a', amount: 1500, currency: 'GBP'),
        const Transfer(from: 'c', to: 'a', amount: 3000, currency: 'GBP'),
      ]);
    });

    test('nets opposite debts per pair, drops zeros', () {
      final g = groupOf(abc, [
        expense(equalBlock(1000, 'a', ['a', 'b'])),
        expense(equalBlock(1000, 'b', ['a', 'b'])),
      ]);
      expect(BalanceCalculator.pairwiseDebts(g), isEmpty);
    });

    test('keeps cycles that simplify would remove', () {
      final g = groupOf(abc, [
        expense(rawBlock({'a': 100}, {'b': 100})),
        expense(rawBlock({'b': 100}, {'c': 100})),
        expense(rawBlock({'c': 100}, {'a': 100})),
      ]);
      expect(BalanceCalculator.groupNets(g), isEmpty);
      expect(BalanceCalculator.pairwiseDebts(g), [
        const Transfer(from: 'a', to: 'c', amount: 100, currency: 'GBP'),
        const Transfer(from: 'b', to: 'a', amount: 100, currency: 'GBP'),
        const Transfer(from: 'c', to: 'b', amount: 100, currency: 'GBP'),
      ]);
    });

    test('multiple payers in proportion to what they paid', () {
      final g = groupOf(abc, [
        expense(rawBlock({'a': 600, 'b': 300}, {'a': 300, 'b': 300, 'c': 300})),
      ]);
      // b owes a 200 (b's 300 split 2:1, 100 of it to b itself);
      // c owes a 200 and b 100.
      expect(BalanceCalculator.pairwiseDebts(g), [
        const Transfer(from: 'b', to: 'a', amount: 100, currency: 'GBP'),
        const Transfer(from: 'c', to: 'a', amount: 200, currency: 'GBP'),
        const Transfer(from: 'c', to: 'b', amount: 100, currency: 'GBP'),
      ]);
    });

    test('rounding never leaves a payer over- or under-repaid', () {
      // Independent allocation per ower would give a both pennies.
      final g = groupOf([...abc, member('d')], [
        expense(rawBlock({'a': 1, 'b': 1}, {'c': 1, 'd': 1})),
      ]);
      final t = BalanceCalculator.pairwiseDebts(g);
      expect(t, [
        const Transfer(from: 'c', to: 'a', amount: 1, currency: 'GBP'),
        const Transfer(from: 'd', to: 'b', amount: 1, currency: 'GBP'),
      ]);
      _expectSettles(BalanceCalculator.groupNets(g), t);
    });

    test('sorted by currency, from, to', () {
      final g = groupOf(abc, [
        expense(equalBlock(100, 'c', ['b', 'c'], currency: 'USD')),
        expense(equalBlock(100, 'b', ['a', 'b'])),
        expense(equalBlock(100, 'a', ['a', 'c'], currency: 'EUR')),
        expense(equalBlock(100, 'c', ['a', 'c'])),
      ]);
      final t = BalanceCalculator.pairwiseDebts(g);
      expect(t.map((x) => '${x.currency}:${x.from}>${x.to}'),
          ['EUR:c>a', 'GBP:a>b', 'GBP:a>c', 'USD:b>c']);
    });

    test('merged payers and owers are combined first', () {
      final g = groupOf([...abc, member('a2', mergedInto: 'a')], [
        expense(rawBlock({'a': 100, 'a2': 200}, {'a2': 100, 'c': 200})),
      ]);
      expect(BalanceCalculator.pairwiseDebts(g), [
        const Transfer(from: 'c', to: 'a', amount: 200, currency: 'GBP'),
      ]);
    });

    test('property: pairwise debts settle the nets exactly', () {
      final rnd = math.Random(99);
      const ids = ['a', 'b', 'c', 'd', 'e', 'f'];
      for (var i = 0; i < 500; i++) {
        final members = [for (final id in ids) member(id)];
        final expenses = <Expense>[];
        for (var k = 0; k < 1 + rnd.nextInt(8); k++) {
          final total = 1 + rnd.nextInt(rnd.nextBool() ? 20 : 100000);
          final payers = (List.of(ids)..shuffle(rnd)).take(1 + rnd.nextInt(3));
          final owers = (List.of(ids)..shuffle(rnd)).take(1 + rnd.nextInt(6));
          expenses.add(expense(SplitCalculator.buildMoneyBlock(
            total: total,
            currency: rnd.nextBool() ? 'GBP' : 'EUR',
            paidBy: SplitSpec.equal(payers),
            owedBy: SplitSpec(SplitMethod.shares,
                {for (final o in owers) o: 1 + rnd.nextInt(5)}),
          )));
        }
        final g = groupOf(members, expenses);
        final nets = BalanceCalculator.groupNets(g);
        _expectNetsSumToZero(nets);
        final t = BalanceCalculator.pairwiseDebts(g);
        _expectSettles(nets, t);
        // Each unordered pair appears at most once per currency.
        final pairs = <String>{};
        for (final x in t) {
          final key = ([x.from, x.to]..sort()).join() + x.currency;
          expect(pairs.add(key), isTrue);
        }
      }
    });
  });

  group('suggestedTransfers', () {
    final expenses = [
      expense(equalBlock(9000, 'a', ['a', 'b', 'c'])),
      expense(rawBlock({'b': 3000}, {'a': 1500, 'b': 1500})),
      expense(equalBlock(200, 'c', ['a', 'c'], currency: 'EUR')),
    ];

    test('simplify on: greedy over nets per currency, ascending code', () {
      final g = groupOf(abc, expenses, simplify: true);
      expect(BalanceCalculator.suggestedTransfers(g), [
        const Transfer(from: 'a', to: 'c', amount: 100, currency: 'EUR'),
        const Transfer(from: 'c', to: 'a', amount: 3000, currency: 'GBP'),
        const Transfer(from: 'b', to: 'a', amount: 1500, currency: 'GBP'),
      ]);
    });

    test('simplify off: the pairwise view', () {
      final g = groupOf(abc, expenses, simplify: false);
      expect(BalanceCalculator.suggestedTransfers(g),
          BalanceCalculator.pairwiseDebts(g));
    });

    test('a group without its create op uses the pairwise view', () {
      final g = groupOf(abc, expenses, simplify: true);
      final bare = GroupState(
          groupId: 'g', group: null, members: g.members, expenses: g.expenses);
      expect(BalanceCalculator.suggestedTransfers(bare),
          BalanceCalculator.pairwiseDebts(g));
    });
  });
}
