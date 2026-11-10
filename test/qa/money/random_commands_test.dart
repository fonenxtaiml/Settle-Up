// QA MONEY: seeded random command sequences over two phones (real Ledger,
// real providers): add / edit / delete / restore expenses, payments and
// updatePayment, merges, removals, simplify toggles and currency changes,
// with periodic syncs. Every money invariant is re-checked after every
// command, and both phones must agree after a final sync.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';

import 'money_harness.dart';

const currencies = ['INR', 'JPY', 'KWD', 'USD'];

void main() {
  for (final seed in [1, 2, 3, 4, 5, 6]) {
    test('seed $seed', () async {
      final r = Random(seed);
      final p = await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa');
      final q = await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb');
      addTearDown(() async {
        await p.dispose();
        await q.dispose();
      });
      final t = await p.group([
        'Sam',
        'Priya',
        'Dev',
        'Eve',
      ], simplify: r.nextBool());
      final g = t.g;
      await shareGroup(p, q, g);
      await syncBoth(p, q, g);
      final members = t.m.values.toList();

      // Random.nextInt stops at 2^32; Money.maxMinor is above it.
      int below(int n) => n <= 1 << 32
          ? r.nextInt(n)
          : (r.nextDouble() * n).floor().clamp(0, n - 1);

      SplitSpec randomSpec(int total, {bool payer = false}) {
        final who = (members.toList()..shuffle(r))
            .take(1 + r.nextInt(5))
            .toList();
        final methods = payer
            ? const [
                SplitMethod.equal,
                SplitMethod.exact,
                SplitMethod.percent,
                SplitMethod.shares,
              ]
            : SplitMethod.values;
        switch (methods[r.nextInt(methods.length)]) {
          case SplitMethod.equal:
            return SplitSpec.equal(who);
          case SplitMethod.exact:
            final v = <MemberId, int>{};
            var left = total;
            for (var i = 0; i < who.length; i++) {
              final x = i == who.length - 1 ? left : below(left + 1);
              v[who[i]] = x;
              left -= x;
            }
            if (v.values.every((x) => x == 0)) v[who.first] = total;
            return SplitSpec(SplitMethod.exact, v);
          case SplitMethod.percent:
            final v = <MemberId, int>{};
            var left = 10000;
            for (var i = 0; i < who.length; i++) {
              final x = i == who.length - 1 ? left : r.nextInt(left + 1);
              v[who[i]] = x;
              left -= x;
            }
            return SplitSpec(SplitMethod.percent, v);
          case SplitMethod.shares:
            return SplitSpec(SplitMethod.shares, {
              for (final m in who) m: 1 + r.nextInt(r.nextBool() ? 3 : 1000),
            });
          case SplitMethod.adjustment:
            final cap = total ~/ (2 * who.length);
            return SplitSpec(SplitMethod.adjustment, {
              for (final m in who) m: cap == 0 ? 0 : below(cap + 1) - cap ~/ 3,
            });
        }
      }

      final expenses = <ExpenseId>[];
      final payments = <ExpenseId>[];
      var commands = 0;
      for (var step = 0; step < 120; step++) {
        final phone = r.nextInt(3) == 0 ? q : p;
        phone.tick(1 + r.nextInt(5000));
        final total = r.nextInt(10) == 0
            ? Money.maxMinor - r.nextInt(1000)
            : 1 + r.nextInt(r.nextBool() ? 100 : 500000);
        final cur = currencies[r.nextInt(currencies.length)];
        ExpenseDraft draft() => ExpenseDraft(
          groupId: g,
          description: 'E$step',
          total: total,
          currency: cur,
          paidBy: randomSpec(total, payer: true),
          owedBy: randomSpec(total),
          category: 'general',
          date: utcFromMillis(kBaseMs + step * 60000),
        );
        String what = '';
        try {
          switch (r.nextInt(12)) {
            case 0 || 1 || 2 || 3:
              what = 'add';
              expenses.add(await phone.ledger.addExpense(draft()));
            case 4 when expenses.isNotEmpty:
              what = 'edit';
              await phone.ledger.updateExpense(
                expenses[r.nextInt(expenses.length)],
                draft(),
              );
            case 5 when expenses.isNotEmpty:
              what = 'delete';
              await phone.ledger.deleteExpense(
                expenses[r.nextInt(expenses.length)],
              );
            case 6 when expenses.isNotEmpty:
              what = 'restore';
              await phone.ledger.restoreExpense(
                expenses[r.nextInt(expenses.length)],
              );
            case 7:
              what = 'pay';
              final from = members[r.nextInt(members.length)];
              final to = members.firstWhere((m) => m != from);
              payments.add(
                await phone.ledger.recordPayment(
                  PaymentDraft(
                    groupId: g,
                    from: from,
                    to: to,
                    amount: total,
                    currency: cur,
                    method: PaymentMethod.cash,
                    date: utcFromMillis(kBaseMs),
                  ),
                ),
              );
            case 8 when payments.isNotEmpty:
              what = 'updatePayment';
              final a = members[r.nextInt(members.length)];
              final b = members[(members.indexOf(a) + 1) % members.length];
              await phone.ledger.updatePayment(
                payments[r.nextInt(payments.length)],
                PaymentDraft(
                  groupId: g,
                  from: a,
                  to: b,
                  amount: total,
                  currency: cur,
                  method: PaymentMethod.bank,
                  date: utcFromMillis(kBaseMs),
                ),
              );
            case 9:
              what = 'simplify';
              await phone.ledger.updateGroup(
                g,
                GroupPatch(simplifyDebts: r.nextBool()),
              );
            case 10 when r.nextInt(4) == 0:
              what = 'merge';
              final a = members[1 + r.nextInt(members.length - 1)];
              final b = members[r.nextInt(members.length)];
              await phone.ledger.mergeMembers(g, from: a, into: b);
            case 11 when r.nextInt(4) == 0:
              what = 'remove';
              await phone.ledger.removeMember(
                g,
                members[1 + r.nextInt(members.length - 1)],
              );
            default:
              what = 'sync';
              await syncBoth(p, q, g);
          }
          commands++;
        } on LedgerException {
          // Random input may be refused (e.g. negative adjustment share,
          // merge of already-merged members); refusing is fine.
        }
        await pumpEventQueue();
        expectMoneyInvariants(phone, reason: 'seed $seed step $step $what');
      }
      await syncBoth(p, q, g);
      expect(q.state.toCanonicalJson(), p.state.toCanonicalJson());
      expect(q.nets(g), p.nets(g));
      expect(q.transfers(g), p.transfers(g));
      expectMoneyInvariants(p, reason: 'final p');
      expectMoneyInvariants(q, reason: 'final q');
      expect(commands, greaterThan(60));
    });
  }
}
