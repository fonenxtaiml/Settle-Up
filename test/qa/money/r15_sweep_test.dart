// QA MONEY round 15: final regression sweep on the integrated build.
//
// Three phones on the real Ledger and providers, each claiming its own
// member, run seeded random commands (expenses with every split method and
// currency, edits that change amount, split, payer and currency, delete,
// restore, payments and updatePayment, merges that may form cycles across
// phones, removals, new members, renames, group currency and simplify
// toggles) with random pairwise syncs. After every command the harness
// invariants are re-checked plus an independent oracle: nets recomputed
// from the stored money blocks, merge resolution idempotent and
// cycle-consistent, every stored share positive, my per-person total the
// same with simplify on and off, and every payment a single from/to block.
// All three phones must converge after a final sync round.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/csv_export.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';

import 'money_harness.dart';

const _currencies = ['INR', 'JPY', 'KWD', 'USD', 'EUR'];

/// Nets recomputed from the money blocks, without BalanceCalculator.
Map<String, Map<MemberId, int>> _oracleNets(GroupState g) {
  final out = <String, Map<MemberId, int>>{};
  for (final e in g.expenses.values) {
    if (e.isDeleted) continue;
    final m = e.money;
    var paid = 0, owed = 0;
    var positive = true;
    m.paid.forEach((_, v) {
      paid += v;
      positive &= v > 0;
    });
    m.owed.forEach((_, v) {
      owed += v;
      positive &= v > 0;
    });
    if (m.total <= 0 || paid != m.total || owed != m.total || !positive) {
      continue;
    }
    final cur = out.putIfAbsent(m.currency, () => {});
    m.paid.forEach((k, v) => cur[g.resolve(k)] = (cur[g.resolve(k)] ?? 0) + v);
    m.owed.forEach((k, v) => cur[g.resolve(k)] = (cur[g.resolve(k)] ?? 0) - v);
  }
  for (final c in out.keys.toList()) {
    out[c]!.removeWhere((_, v) => v == 0);
    if (out[c]!.isEmpty) out.remove(c);
  }
  return out;
}

Map<String, int> _mineFrom(List<Transfer> ts, MemberId my) {
  final out = <String, int>{};
  for (final t in ts) {
    if (t.to == my) out[t.currency] = (out[t.currency] ?? 0) + t.amount;
    if (t.from == my) out[t.currency] = (out[t.currency] ?? 0) - t.amount;
  }
  out.removeWhere((_, v) => v == 0);
  return out;
}

void _expectOracle(QaPhone p, String why) {
  for (final g in p.state.visibleGroups) {
    final nets = p.nets(g.groupId);
    expect(nets, _oracleNets(g), reason: 'nets == oracle ($why)');
    for (final id in g.members.keys) {
      final r = g.resolve(id);
      expect(g.resolve(r), r, reason: 'resolve idempotent ($why)');
      expect(g.members[r]?.mergedInto == null || g.resolve(r) == r, isTrue);
    }
    for (final e in g.liveExpenses) {
      for (final v in [...e.money.paid.values, ...e.money.owed.values]) {
        expect(v, greaterThan(0), reason: 'no zero/negative share ($why)');
      }
      expect(e.money.total, lessThanOrEqualTo(Money.maxMinor));
      if (e.isPayment) {
        expect(e.money.paid.length, 1, reason: 'payment one payer ($why)');
        expect(e.money.owed.length, 1, reason: 'payment one payee ($why)');
        expect(
          e.money.paid.keys.single,
          isNot(e.money.owed.keys.single),
          reason: 'payment two people ($why)',
        );
      }
    }
    final mine = g.memberForPerson(p.me);
    if (mine == null) continue;
    final my = g.resolve(mine.id);
    final myNet = Summaries.myNetInGroup(g, p.me);
    final simplified = [
      for (final c in nets.keys) ...DebtSimplifier.simplify(nets[c]!, c),
    ];
    final pairwise = BalanceCalculator.cancelCycles(
      BalanceCalculator.pairwiseDebts(g),
    );
    expect(_mineFrom(simplified, my), myNet, reason: 'simplify on ($why)');
    expect(_mineFrom(pairwise, my), myNet, reason: 'simplify off ($why)');
  }
}

void main() {
  test('changing the group currency leaves every expense, payment and net '
      'in its own currency', () async {
    final p = await QaPhone.create();
    addTearDown(p.dispose);
    final t = await p.group(['Sam', 'Priya']);
    final g = t.g, me = t.m['me']!, sam = t.m['Sam']!, priya = t.m['Priya']!;
    await p.add(
      g,
      total: 3001,
      paidBy: one(me, 3001),
      owedBy: eq([me, sam, priya]),
    );
    await p.add(
      g,
      total: 900,
      currency: 'JPY',
      paidBy: one(sam, 900),
      owedBy: eq([me, sam, priya]),
    );
    await p.pay(g, from: priya, to: me, amount: 1000);
    final before = p.nets(g);
    final people = p.people();
    final overall = p.overall().net;
    for (final c in ['USD', 'KWD', 'INR']) {
      p.tick();
      await p.ledger.updateGroup(g, GroupPatch(currency: c));
      await pumpEventQueue();
      expect(p.gs(g).group!.currency, c);
      expect(p.nets(g), before);
      expect(p.people().map((x) => x.net), people.map((x) => x.net));
      expect(p.overall().net, overall);
      expect(
        {for (final e in p.gs(g).liveExpenses) e.money.currency},
        {'INR', 'JPY'},
      );
      expectMoneyInvariants(p, reason: 'group currency $c');
      _expectOracle(p, 'group currency $c');
    }
    // 3001 over three: the extra paisa goes to the lowest id.
    final ids = [me, sam, priya]..sort();
    final e = p.gs(g).liveExpenses.firstWhere((x) => x.money.total == 3001);
    expect(e.money.owed[ids.first], 1001);
  });

  for (final seed in [1501, 1502, 1503, 1504, 1505, 1506, 1507, 1508]) {
    test('three phones, seed $seed', () async {
      final r = Random(seed);
      final p = await QaPhone.create(name: 'Alex', prefix: 'cccccccc');
      final q = await QaPhone.create(name: 'Sam', prefix: 'dddddddd');
      final s = await QaPhone.create(name: 'Priya', prefix: 'eeeeeeee');
      addTearDown(() async {
        await p.dispose();
        await q.dispose();
        await s.dispose();
      });
      final t = await p.group([
        'Sam',
        'Priya',
        'Dev',
        'Eve',
        'Kim',
      ], simplify: r.nextBool());
      final g = t.g;
      await shareGroup(p, q, g);
      await shareGroup(p, s, g);
      await syncBoth(p, q, g);
      await syncBoth(p, s, g);
      await q.ledger.claimMember(g, t.m['Sam']!);
      await s.ledger.claimMember(g, t.m['Priya']!);
      await syncBoth(q, p, g);
      await syncBoth(s, p, g);
      await syncBoth(q, s, g);
      final phones = [p, q, s];
      final members = t.m.values.toList();

      int below(int n) => n <= 1 << 32
          ? r.nextInt(n)
          : (r.nextDouble() * n).floor().clamp(0, n - 1);

      SplitSpec randomSpec(int total, {bool payer = false}) {
        final who = (members.toList()..shuffle(r))
            .take(1 + r.nextInt(members.length))
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
              for (final m in who)
                m: r.nextInt(5) == 0
                    ? 0
                    : 1 + r.nextInt(r.nextBool() ? 3 : 1000),
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
      for (var step = 0; step < 150; step++) {
        final phone = phones[r.nextInt(3)];
        phone.tick(1 + r.nextInt(5000));
        final total = switch (r.nextInt(12)) {
          0 => Money.maxMinor - r.nextInt(3),
          1 => 1 + r.nextInt(3),
          _ => 1 + r.nextInt(r.nextBool() ? 100 : 500000),
        };
        final cur = _currencies[r.nextInt(_currencies.length)];
        ExpenseDraft draft() => ExpenseDraft(
          groupId: g,
          description: '=E$step,"x"',
          total: total,
          currency: cur,
          paidBy: randomSpec(total, payer: true),
          owedBy: randomSpec(total),
          category: 'general',
          date: utcFromMillis(kBaseMs + step * 60000),
        );
        var what = '';
        try {
          switch (r.nextInt(16)) {
            case 0 || 1 || 2 || 3:
              what = 'add';
              expenses.add(await phone.ledger.addExpense(draft()));
            case 4 || 5 when expenses.isNotEmpty:
              what = 'edit';
              await phone.ledger.updateExpense(
                expenses[r.nextInt(expenses.length)],
                draft(),
              );
            case 6 when expenses.isNotEmpty:
              what = 'delete';
              await phone.ledger.deleteExpense(
                expenses[r.nextInt(expenses.length)],
              );
            case 7 when expenses.isNotEmpty:
              what = 'restore';
              await phone.ledger.restoreExpense(
                expenses[r.nextInt(expenses.length)],
              );
            case 8:
              what = 'pay';
              final from = members[r.nextInt(members.length)];
              final to = members[r.nextInt(members.length)];
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
            case 9 when payments.isNotEmpty:
              what = 'updatePayment';
              final a = members[r.nextInt(members.length)];
              final b = members[r.nextInt(members.length)];
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
            case 10:
              what = 'group settings';
              await phone.ledger.updateGroup(
                g,
                GroupPatch(
                  simplifyDebts: r.nextBool(),
                  currency: r.nextBool() ? cur : null,
                ),
              );
            case 11 when r.nextInt(3) == 0:
              what = 'merge';
              await phone.ledger.mergeMembers(
                g,
                from: members[r.nextInt(members.length)],
                into: members[r.nextInt(members.length)],
              );
            case 12 when r.nextInt(4) == 0:
              what = 'remove';
              await phone.ledger.removeMember(
                g,
                members[r.nextInt(members.length)],
              );
            case 13 when r.nextInt(3) == 0:
              what = 'addMember';
              members.add(
                await phone.ledger.addMember(g, displayName: 'N$step'),
              );
            case 14:
              what = 'rename';
              await phone.ledger.renameMember(
                g,
                members[r.nextInt(members.length)],
                'R$step',
              );
            default:
              what = 'sync';
              final a = phones[r.nextInt(3)];
              final b = phones.firstWhere((x) => x != a);
              await syncBoth(a, b, g);
          }
          commands++;
        } on LedgerException {
          // Random input may be refused; refusing is fine.
        }
        await pumpEventQueue();
        for (final x in phones) {
          final why = 'seed $seed step $step $what';
          expectMoneyInvariants(x, reason: why);
          _expectOracle(x, why);
        }
      }
      for (var i = 0; i < 2; i++) {
        await syncBoth(p, q, g);
        await syncBoth(q, s, g);
        await syncBoth(s, p, g);
      }
      for (final x in [q, s]) {
        expect(x.state.toCanonicalJson(), p.state.toCanonicalJson());
        expect(x.nets(g), p.nets(g));
        expect(x.transfers(g), p.transfers(g));
      }
      for (final x in phones) {
        expectMoneyInvariants(x, reason: 'final');
        _expectOracle(x, 'final');
      }
      // CSV of the converged group: one row per live expense, none of the
      // deleted ones, no formula-leading cell.
      final gs = p.gs(g);
      final csv = CsvExport.group(gs);
      final lines = csv.split('\r\n').where((l) => l.isNotEmpty).toList();
      expect(lines.length - 1, gs.liveExpenses.length);
      expect(
        csv.contains(RegExp(r'(^|,)"?[=+@\t\r]', multiLine: true)),
        isFalse,
      );
      expect(commands, greaterThan(80));
    });
  }
}
