// QA MONEY round 21: final regression sweep on the integrated build.
//
// New since the round 15 sweep: the reducer folds a sync batch into the
// LWW registers and rebuilds each entity once after the last op of the
// batch (DATA-R15-01), and the Ledger feeds every applyRemote batch through
// that path. These probes check that the money a phone shows does not
// depend on how the ops reached it: one big batch (the bulk path, more than
// 64 ops), one op per batch in random order, or reversed chunks, after two
// phones wrote concurrent edits, deletes, restores, payments, merges and
// removals. They also re-run the charter's riskiest edges through the
// Ledger and the providers.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';

import 'money_harness.dart';

const _currencies = ['INR', 'JPY', 'KWD', 'USD'];

Future<List<Operation>> _allOps(QaPhone from, GroupId g) =>
    from.ledger.opsMissingFor(g, VersionVector.empty);

void _expectSame(QaPhone x, QaPhone ref, GroupId g, String why) {
  expect(
    x.state.toCanonicalJson(),
    ref.state.toCanonicalJson(),
    reason: 'state $why',
  );
  expect(x.nets(g), ref.nets(g), reason: 'nets $why');
  expect(x.transfers(g), ref.transfers(g), reason: 'transfers $why');
  expectMoneyInvariants(x, reason: why);
}

void main() {
  for (final seed in [2101, 2102, 2103, 2104, 2105, 2106]) {
    test('how a batch arrives does not change the money, seed $seed', () async {
      final r = Random(seed);
      final a = await QaPhone.create(name: 'Alex', prefix: 'a1a1a1a1');
      final b = await QaPhone.create(name: 'Sam', prefix: 'b2b2b2b2');
      final one = await QaPhone.create(name: 'Kim', prefix: 'c3c3c3c3');
      final each = await QaPhone.create(name: 'Lee', prefix: 'd4d4d4d4');
      final rev = await QaPhone.create(name: 'Max', prefix: 'e5e5e5e5');
      final receivers = [one, each, rev];
      addTearDown(() async {
        for (final p in [a, b, ...receivers]) {
          await p.dispose();
        }
      });
      final t = await a.group(['Sam', 'Priya', 'Dev'], simplify: r.nextBool());
      final g = t.g;
      await shareGroup(a, b, g);
      await syncBoth(a, b, g);
      await b.ledger.claimMember(g, t.m['Sam']!);
      await syncBoth(a, b, g);
      final members = t.m.values.toList();
      final expenses = <ExpenseId>[];
      final payments = <ExpenseId>[];

      int below(int n) => n <= 1 << 32
          ? r.nextInt(n)
          : (r.nextDouble() * n).floor().clamp(0, n - 1);

      SplitSpec spec(int total, {bool payer = false}) {
        final who = (members.toList()..shuffle(r))
            .take(1 + r.nextInt(members.length))
            .toList();
        final m = payer ? r.nextInt(4) : r.nextInt(5);
        switch (m) {
          case 0:
            return SplitSpec.equal(who);
          case 1:
            final v = <MemberId, int>{};
            var left = total;
            for (var i = 0; i < who.length; i++) {
              final x = i == who.length - 1 ? left : below(left + 1);
              v[who[i]] = x;
              left -= x;
            }
            return SplitSpec(SplitMethod.exact, v);
          case 2:
            final v = <MemberId, int>{};
            var left = 10000;
            for (var i = 0; i < who.length; i++) {
              final x = i == who.length - 1 ? left : r.nextInt(left + 1);
              v[who[i]] = x;
              left -= x;
            }
            return SplitSpec(SplitMethod.percent, v);
          case 3:
            return SplitSpec(SplitMethod.shares, {
              for (final x in who) x: r.nextInt(4) == 0 ? 0 : 1 + r.nextInt(9),
            });
          default:
            final cap = total ~/ (2 * who.length);
            return SplitSpec(SplitMethod.adjustment, {
              for (final x in who) x: cap == 0 ? 0 : below(cap + 1) - cap ~/ 3,
            });
        }
      }

      for (var step = 0; step < 260; step++) {
        final phone = r.nextBool() ? a : b;
        phone.tick(1 + r.nextInt(4000));
        final total = r.nextInt(10) == 0
            ? Money.maxMinor
            : 1 + r.nextInt(r.nextBool() ? 10 : 200000);
        final cur = _currencies[r.nextInt(_currencies.length)];
        ExpenseDraft draft() => ExpenseDraft(
          groupId: g,
          description: 'E$step',
          total: total,
          currency: cur,
          paidBy: spec(total, payer: true),
          owedBy: spec(total),
          category: 'general',
          date: utcFromMillis(kBaseMs + step * 60000),
        );
        try {
          switch (r.nextInt(14)) {
            case 0 || 1 || 2 || 3:
              expenses.add(await phone.ledger.addExpense(draft()));
            case 4 || 5 when expenses.isNotEmpty:
              await phone.ledger.updateExpense(
                expenses[r.nextInt(expenses.length)],
                draft(),
              );
            case 6 when expenses.isNotEmpty:
              await phone.ledger.deleteExpense(
                expenses[r.nextInt(expenses.length)],
              );
            case 7 when expenses.isNotEmpty:
              await phone.ledger.restoreExpense(
                expenses[r.nextInt(expenses.length)],
              );
            case 8:
              payments.add(
                await phone.ledger.recordPayment(
                  PaymentDraft(
                    groupId: g,
                    from: members[r.nextInt(members.length)],
                    to: members[r.nextInt(members.length)],
                    amount: total,
                    currency: cur,
                    method: PaymentMethod.cash,
                    date: utcFromMillis(kBaseMs),
                  ),
                ),
              );
            case 9 when payments.isNotEmpty:
              await phone.ledger.updatePayment(
                payments[r.nextInt(payments.length)],
                PaymentDraft(
                  groupId: g,
                  from: members[r.nextInt(members.length)],
                  to: members[r.nextInt(members.length)],
                  amount: total,
                  currency: cur,
                  method: PaymentMethod.upi,
                  date: utcFromMillis(kBaseMs),
                ),
              );
            case 10 when r.nextInt(4) == 0:
              await phone.ledger.mergeMembers(
                g,
                from: members[r.nextInt(members.length)],
                into: members[r.nextInt(members.length)],
              );
            case 11 when r.nextInt(5) == 0:
              await phone.ledger.removeMember(
                g,
                members[r.nextInt(members.length)],
              );
            case 12:
              await phone.ledger.updateGroup(
                g,
                GroupPatch(simplifyDebts: r.nextBool()),
              );
            default:
              if (r.nextInt(3) == 0) await syncBoth(a, b, g);
          }
        } on LedgerException {
          // Random input may be refused.
        }
        await pumpEventQueue();
      }
      await syncBoth(a, b, g);
      await syncBoth(a, b, g);
      _expectSame(b, a, g, 'writers');

      final ops = await _allOps(a, g);
      expect(ops.length, greaterThan(64), reason: 'bulk path');
      for (final p in receivers) {
        await shareGroup(a, p, g);
        p.tick(10 * 60 * 1000 * 1000);
      }
      // One batch.
      await one.ledger.applyRemote(g, ops);
      await pumpEventQueue();
      // One op per batch, shuffled.
      final shuffled = ops.toList()..shuffle(r);
      for (final op in shuffled) {
        await each.ledger.applyRemote(g, [op]);
      }
      await pumpEventQueue();
      // Reversed, in chunks of random size, each chunk once more (dups).
      final reversed = ops.reversed.toList();
      for (var i = 0; i < reversed.length;) {
        final n = 1 + r.nextInt(40);
        final chunk = reversed.sublist(i, min(i + n, reversed.length));
        await rev.ledger.applyRemote(g, chunk);
        await rev.ledger.applyRemote(g, chunk);
        i += n;
      }
      await pumpEventQueue();
      for (final p in receivers) {
        _expectSame(p, a, g, 'receiver ${p.settings.profile!.displayName}');
      }
      // Simplify on/off over the same nets: same per-person totals,
      // at most n-1 transfers when on.
      final nets = a.nets(g);
      for (final entry in nets.entries) {
        final n = entry.value.values.where((v) => v != 0).length;
        final mine = a
            .transfers(g)
            .where((x) => x.currency == entry.key)
            .toList();
        if (a.gs(g).group!.simplifyDebts) {
          expect(mine.length, lessThanOrEqualTo(max(0, n - 1)));
        }
        final per = <MemberId, int>{};
        for (final x in mine) {
          per[x.from] = (per[x.from] ?? 0) - x.amount;
          per[x.to] = (per[x.to] ?? 0) + x.amount;
        }
        for (final m in entry.value.entries) {
          expect(per[m.key] ?? 0, m.value, reason: 'transfers settle nets');
        }
      }
    });
  }

  test('an edit, a delete and a restore of one expense in one batch '
      'land as the 7.2 table says, whatever their order', () async {
    final a = await QaPhone.create(name: 'Alex', prefix: 'a7a7a7a7');
    final b = await QaPhone.create(name: 'Sam', prefix: 'b7b7b7b7');
    final x = await QaPhone.create(name: 'Kim', prefix: 'c7c7c7c7');
    final y = await QaPhone.create(name: 'Lee', prefix: 'd7d7d7d7');
    addTearDown(() async {
      for (final p in [a, b, x, y]) {
        await p.dispose();
      }
    });
    final t = await a.group(['Sam', 'Priya']);
    final g = t.g;
    await shareGroup(a, b, g);
    final me = t.m['me']!;
    final sam = t.m['Sam']!;
    final priya = t.m['Priya']!;
    final e = await a.add(
      g,
      total: 30000,
      paidBy: SplitSpec.single(me, 30000),
      owedBy: SplitSpec.equal([me, sam, priya]),
    );
    await syncBoth(a, b, g);
    // A deletes; B, later on its clock and unaware, edits the amount; then
    // A restores after seeing nothing from B.
    a.tick();
    await a.ledger.deleteExpense(e);
    b.tick(5000);
    await b.ledger.updateExpense(
      e,
      ExpenseDraft(
        groupId: g,
        description: 'Dinner',
        total: 45000,
        currency: 'INR',
        paidBy: SplitSpec.single(sam, 45000),
        owedBy: SplitSpec.equal([me, sam, priya]),
        category: 'food.dining',
        date: utcFromMillis(kBaseMs),
      ),
    );
    a.tick(10000);
    await a.ledger.restoreExpense(e);
    await syncBoth(a, b, g);
    await syncBoth(a, b, g);
    expect(a.state.toCanonicalJson(), b.state.toCanonicalJson());
    final live = a.state.expense(e)!;
    expect(live.isDeleted, isFalse);
    expect(live.money.total, 45000, reason: 'edit after delete then restore');
    expect(a.nets(g)['INR'], {me: -15000, sam: 30000, priya: -15000});

    final ops = await _allOps(a, g);
    for (final p in [x, y]) {
      await shareGroup(a, p, g);
      p.tick(1 << 30);
    }
    await x.ledger.applyRemote(g, ops);
    for (final op in ops.reversed) {
      await y.ledger.applyRemote(g, [op]);
    }
    await pumpEventQueue();
    for (final p in [x, y]) {
      _expectSame(p, a, g, p.settings.profile!.displayName);
    }
  });
}
