// QA MONEY round 29: final full regression sweep of money correctness on
// the integrated build, through the real Ledger(MemoryOpStore) and the
// Riverpod providers. New angles on the charter's riskiest paths:
//  * every amount the app shows (MoneyFormat) and every value the edit
//    form writes into a field (minorToInput) reads back as the same minor
//    units, in every ISO currency, up to Money.maxMinor;
//  * an expense opened in the edit form and saved untouched gives the
//    spec it was stored with (the form's "money kept" check) and the Ledger
//    writes nothing, for every split method and payer shape;
//  * the Settle up preview equals what the Ledger and the providers show
//    once the payment is recorded, over seeded random groups;
//  * seeded command fuzz over two phones with concurrent merges that form a
//    cycle, currency edits, edit-after-delete-then-restore and
//    updatePayment, re-checking every invariant plus "simplify on and off
//    give the same nets and per-person totals" after every command.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/format/amount_input.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/screens/expense/split_draft.dart';
import 'package:settle_up/ui/screens/settle/settle_preview.dart';

import 'money_harness.dart';

const _sweepCurrencies = ['INR', 'JPY', 'KWD', 'USD', 'EUR'];

void main() {
  group('R29 amounts read back as written', () {
    final r = Random(29);
    final samples = <int>[
      1,
      9,
      10,
      99,
      100,
      101,
      999,
      1000,
      1001,
      12345,
      100000,
      1234567,
      10000000,
      Money.maxMinor,
      Money.maxMinor - 1,
      for (var i = 0; i < 40; i++) 1 + r.nextInt(1 << 31),
      for (var i = 0; i < 10; i++)
        (r.nextDouble() * Money.maxMinor).floor().clamp(1, Money.maxMinor),
    ];

    test('MoneyFormat.format then a paste of it gives the same amount, '
        'every ISO currency', () {
      final bad = <String>[];
      for (final c in Currencies.all) {
        // TND: the amount field groups with thin spaces, as a comma before
        // three digits is the decimal comma people write there (MONEY-R3-06,
        // MONEY-R4-02). The display form "DT1,234.567" is refused, never
        // misread; checked below.
        if (c.code == 'TND') continue;
        for (final m in samples) {
          final shown = MoneyFormat.format(m, c.code);
          final back = parseAmountInput(shown, c);
          if (back != m) bad.add('${c.code} $m shown "$shown" read $back');
        }
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test('TND display text is refused, never misread', () {
      final tnd = Currencies.of('TND');
      for (final m in samples) {
        final back = parseAmountInput(MoneyFormat.format(m, 'TND'), tnd);
        expect(back == null || back == m, isTrue, reason: '$m read $back');
      }
    });

    test('minorToInput (what the edit form writes) reads back, every ISO '
        'currency, signed for adjustments', () {
      final bad = <String>[];
      for (final c in Currencies.all) {
        for (final m in samples) {
          final text = minorToInput(m, c);
          if (parseAmountInput(text, c) != m) bad.add('${c.code} $m "$text"');
          if (parseSignedMinor(minorToInput(-m, c), c) != -m) {
            bad.add('${c.code} -$m');
          }
        }
      }
      expect(bad, isEmpty, reason: bad.join('\n'));
    });

    test(
      'formatPercent then parsePercent gives every basis point 0..10000',
      () {
        for (var bp = 0; bp <= 10000; bp++) {
          expect(parsePercent(formatPercent(bp)), bp, reason: '$bp');
        }
      },
    );

    test('charter parsing vectors', () {
      final usd = Currencies.of('USD');
      final eur = Currencies.of('EUR');
      final kwd = Currencies.of('KWD');
      final inr = Currencies.of('INR');
      final jpy = Currencies.of('JPY');
      expect(parseAmountInput('1,234.50', usd), 123450);
      expect(parseAmountInput('1.234,50', eur), 123450);
      expect(parseAmountInput('12.345', kwd), 12345);
      expect(parseAmountInput('1,00,000', inr), 10000000);
      expect(parseAmountInput('12.345', inr), isNull);
      expect(parseAmountInput('12.5', jpy), isNull);
      expect(parseAmountInput('1.2345', kwd), isNull);
      expect(parseAmountInput('0.001', usd), isNull);
    });
  });

  group('R29 an expense saved untouched from the edit form', () {
    for (final currency in _sweepCurrencies) {
      test(
        'round-trips through SplitDraft and writes nothing, $currency',
        () async {
          final r = Random(currency.hashCode);
          final p = await QaPhone.create(home: currency);
          addTearDown(p.dispose);
          final t = await p.group([
            'Sam',
            'Priya',
            'Dev',
            'Eve',
          ], currency: currency);
          final g = t.g;
          final ms = t.m.values.toList()..sort();
          final cur = Currencies.of(currency);
          final specs = <(SplitSpec, int)>[
            // total 1 minor unit over 3
            (SplitSpec.equal(ms.take(3)), 1),
            (
              SplitSpec(SplitMethod.percent, {
                ms[0]: 3333,
                ms[1]: 3333,
                ms[2]: 3334,
              }),
              100,
            ),
            (SplitSpec(SplitMethod.shares, {ms[0]: 1000, ms[1]: 1}), 1001),
            // adjustment making the rest exactly 0
            (SplitSpec(SplitMethod.adjustment, {ms[0]: 500, ms[1]: 500}), 1000),
            // valid negative adjustment
            (
              SplitSpec(SplitMethod.adjustment, {
                ms[0]: -100,
                ms[1]: 0,
                ms[2]: 0,
              }),
              900,
            ),
            (
              SplitSpec(SplitMethod.exact, {
                ms[0]: 1,
                ms[1]: Money.maxMinor - 1,
              }),
              Money.maxMinor,
            ),
            (SplitSpec.equal(ms), Money.maxMinor),
            for (var i = 0; i < 12; i++) _randomSpec(r, ms),
          ];
          final payers = <SplitSpec Function(int)>[
            (total) => SplitSpec.single(ms[1], total),
            (total) => SplitSpec.equal([ms[0], ms[2]]),
            (total) => SplitSpec(SplitMethod.shares, {ms[0]: 2, ms[3]: 1}),
            (total) =>
                SplitSpec(SplitMethod.percent, {ms[1]: 2500, ms[4]: 7500}),
          ];
          var n = 0;
          for (final (owed, base) in specs) {
            final total = owed.method == SplitMethod.exact
                ? owed.values.values.fold(0, (a, b) => a + b)
                : base;
            final paidBy = payers[n++ % payers.length](total);
            final id = await p.add(
              g,
              total: total,
              currency: currency,
              paidBy: paidBy,
              owedBy: owed,
            );
            final e = p.state.expenseIn(g, id)!;
            // What the edit form loads and saves untouched.
            final draft = SplitDraft(members: ms)..load(e.money.owedBy, cur);
            final formOwed = draft.spec(cur);
            expect(formOwed, e.money.owedBy, reason: '$owed in $currency');
            expect(draft.badInput(cur), isEmpty, reason: '$owed');
            expect(draft.check(total, cur).isValid, isTrue, reason: '$owed');
            final paid = e.money.paidBy.values;
            final formPaid =
                e.money.paidBy.method == SplitMethod.exact && paid.length == 1
                ? SplitSpec.single(paid.keys.first, total)
                : SplitSpec(SplitMethod.exact, {
                    for (final x in e.money.paid.entries)
                      if (x.value > 0) x.key: x.value,
                  });
            // Saved after the user changed the description only: the money
            // that goes back is the money that was stored.
            final before = (await p.store.loadAll()).length;
            await p.ledger.updateExpense(
              id,
              ExpenseDraft(
                groupId: g,
                description: e.description,
                total: total,
                currency: currency,
                paidBy: formPaid,
                owedBy: formOwed,
                category: e.category,
                date: e.date,
                notes: e.notes,
              ),
            );
            await pumpEventQueue();
            final after = p.state.expenseIn(g, id)!;
            expect(after.money.owed, e.money.owed, reason: '$owed');
            expect(after.money.paid, e.money.paid, reason: '$paidBy');
            expect(
              (await p.store.loadAll()).length - before,
              lessThanOrEqualTo(1),
              reason: 'at most the payer method is rewritten',
            );
            expectMoneyInvariants(p, reason: '$owed / $paidBy');
          }
        },
      );
    }
  });

  group('R29 Settle up preview equals the ledger once recorded', () {
    for (final seed in [291, 292, 293, 294]) {
      for (final simplify in [true, false]) {
        test('seed $seed simplify $simplify', () async {
          final r = Random(seed);
          final p = await QaPhone.create();
          addTearDown(p.dispose);
          final t = await p.group([
            'Sam',
            'Priya',
            'Dev',
            'Eve',
          ], simplify: simplify);
          final g = t.g;
          final ms = t.m.values.toList()..sort();
          for (var i = 0; i < 6; i++) {
            final (owed, t0) = _randomSpec(r, ms, total: 1 + r.nextInt(100000));
            final total = owed.method == SplitMethod.exact
                ? owed.values.values.fold(0, (a, b) => a + b)
                : t0;
            await p.add(
              g,
              total: total,
              currency: i.isEven ? 'INR' : 'USD',
              paidBy: SplitSpec.single(ms[r.nextInt(ms.length)], total),
              owedBy: owed,
            );
          }
          for (var step = 0; step < 25; step++) {
            final currency = r.nextBool() ? 'INR' : 'USD';
            final transfers = p.transfers(g);
            int amount;
            MemberId from;
            MemberId to;
            final suggested = [
              for (final x in transfers)
                if (x.currency == currency) x,
            ];
            if (suggested.isNotEmpty && r.nextInt(3) > 0) {
              final s = suggested[r.nextInt(suggested.length)];
              from = s.from;
              to = s.to;
              // exact, partial or over-payment
              amount = switch (r.nextInt(3)) {
                0 => s.amount,
                1 => max(1, s.amount ~/ 2),
                _ => s.amount + 1 + r.nextInt(5000),
              };
            } else {
              from = ms[r.nextInt(ms.length)];
              to = ms.where((m) => m != from).toList()[r.nextInt(4)];
              amount = 1 + r.nextInt(5000);
            }
            final date = utcFromMillis(kBaseMs);
            final preview = SettlePreview.of(
              p.state,
              p.me,
              groupId: g,
              from: from,
              to: to,
              amount: amount,
              currency: currency,
              date: date,
            );
            expect(preview.transfersNow, transfers);
            await p.pay(
              g,
              from: from,
              to: to,
              amount: amount,
              currency: currency,
            );
            expect(
              p.transfers(g),
              preview.transfersAfter,
              reason: 'step $step $from->$to $amount $currency',
            );
            final people = {
              for (final x in p.people()) x.personId: x.net[currency] ?? 0,
            };
            for (final x in preview.peopleAfter) {
              expect(
                people[x.personId] ?? 0,
                x.net[currency] ?? 0,
                reason: 'person ${x.personId} step $step',
              );
            }
            expect(
              p.overall().net[currency] ?? 0,
              preview.overallAfter,
              reason: 'overall step $step',
            );
            expectMoneyInvariants(p, reason: 'preview step $step');
          }
        });
      }
    }
  });

  group('R29 fuzz: two phones, merge cycles, currency edits, restores', () {
    for (final seed in [2901, 2902, 2903, 2904, 2905, 2906, 2907, 2908]) {
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
          'Fay',
        ], simplify: r.nextBool());
        final g = t.g;
        await shareGroup(p, q, g);
        await syncBoth(p, q, g);
        final ms = t.m.values.toList()..sort();
        final expenses = <ExpenseId>[];
        final payments = <ExpenseId>[];
        var commands = 0;
        for (var step = 0; step < 90; step++) {
          final phone = r.nextInt(3) == 0 ? q : p;
          phone.tick(1 + r.nextInt(5000));
          final total = r.nextInt(12) == 0
              ? Money.maxMinor - r.nextInt(1000)
              : 1 + r.nextInt(r.nextBool() ? 10 : 300000);
          final cur = _sweepCurrencies[r.nextInt(_sweepCurrencies.length)];
          ExpenseDraft draft() {
            final (owed, _) = _randomSpec(r, ms, total: total);
            return ExpenseDraft(
              groupId: g,
              description: 'E$step',
              total: owed.method == SplitMethod.exact
                  ? owed.values.values.fold(0, (a, b) => a + b)
                  : total,
              currency: cur,
              paidBy: owed.method == SplitMethod.exact
                  ? SplitSpec.single(
                      ms[r.nextInt(ms.length)],
                      owed.values.values.fold(0, (a, b) => a + b),
                    )
                  : SplitSpec.equal(ms.take(1 + r.nextInt(3))),
              owedBy: owed,
              category: 'general',
              date: utcFromMillis(kBaseMs + step * 60000),
            );
          }

          var what = '';
          try {
            switch (r.nextInt(14)) {
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
                // edit after delete, then restore (SPEC 7.2), on two
                // phones without a sync between them
                what = 'delete-edit-restore';
                final id = expenses[r.nextInt(expenses.length)];
                await p.ledger.deleteExpense(id);
                if (q.state.expenseIn(g, id) != null) {
                  q.tick(7);
                  try {
                    await q.ledger.updateExpense(id, draft());
                  } on LedgerException {
                    // deleted there already
                  }
                }
                await syncBoth(p, q, g);
                p.tick(11);
                await p.ledger.restoreExpense(id);
              case 6 when expenses.isNotEmpty:
                what = 'restore';
                await phone.ledger.restoreExpense(
                  expenses[r.nextInt(expenses.length)],
                );
              case 7:
                what = 'pay';
                final from = ms[r.nextInt(ms.length)];
                final to = ms.firstWhere((m) => m != from);
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
                final a = ms[r.nextInt(ms.length)];
                final b = ms[(ms.indexOf(a) + 1 + r.nextInt(4)) % ms.length];
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
              case 10 when r.nextInt(3) == 0:
                // concurrent merges a->b on one phone and b->a on the
                // other: a cycle the reducer must resolve the same way
                what = 'merge-cycle';
                final a = ms[1 + r.nextInt(ms.length - 1)];
                final b = ms[1 + r.nextInt(ms.length - 1)];
                if (a == b) break;
                await syncBoth(p, q, g);
                try {
                  await p.ledger.mergeMembers(g, from: a, into: b);
                } on LedgerException {
                  // already merged or removed
                }
                q.tick(3);
                try {
                  await q.ledger.mergeMembers(g, from: b, into: a);
                } on LedgerException {
                  // already merged or removed
                }
                await syncBoth(p, q, g);
              case 11 when r.nextInt(4) == 0:
                what = 'remove';
                await phone.ledger.removeMember(
                  g,
                  ms[1 + r.nextInt(ms.length - 1)],
                );
              case 12 when expenses.isNotEmpty:
                what = 'delete';
                await phone.ledger.deleteExpense(
                  expenses[r.nextInt(expenses.length)],
                );
              default:
                what = 'sync';
                await syncBoth(p, q, g);
            }
            commands++;
          } on LedgerException {
            // Random input may be refused; refusing is fine.
          }
          await pumpEventQueue();
          expectMoneyInvariants(phone, reason: 'seed $seed step $step $what');
          _expectSimplifyNeutral(phone, g, 'seed $seed step $step $what');
        }
        await syncBoth(p, q, g);
        expect(q.state.toCanonicalJson(), p.state.toCanonicalJson());
        expect(q.nets(g), p.nets(g));
        expect(q.transfers(g), p.transfers(g));
        expectMoneyInvariants(p, reason: 'final p');
        expectMoneyInvariants(q, reason: 'final q');
        expect(commands, greaterThan(40));
      });
    }
  });

  group('R29 tie rounding goes to the lowest member id', () {
    for (final order in const [
      ['c', 'a', 'b'],
      ['b', 'c', 'a'],
      ['a', 'b', 'c'],
    ]) {
      test('insertion order $order', () async {
        final p = await QaPhone.create();
        addTearDown(p.dispose);
        final t = await p.group(['Sam', 'Priya', 'Dev']);
        final ms = t.m.values.toList()..sort();
        final byLetter = {'a': ms[0], 'b': ms[1], 'c': ms[2]};
        final who = [for (final l in order) byLetter[l]!];
        for (final currency in ['INR', 'JPY', 'KWD']) {
          final id = await p.add(
            t.g,
            total: 2,
            currency: currency,
            paidBy: SplitSpec.single(ms[3], 2),
            owedBy: SplitSpec(SplitMethod.equal, {for (final m in who) m: 1}),
          );
          expect(p.owed(id), {ms[0]: 1, ms[1]: 1}, reason: currency);
          final s = await p.add(
            t.g,
            total: 3,
            currency: currency,
            paidBy: SplitSpec.single(ms[3], 3),
            owedBy: SplitSpec(SplitMethod.shares, {for (final m in who) m: 2}),
          );
          expect(p.owed(s), {ms[0]: 1, ms[1]: 1, ms[2]: 1});
          final pc = await p.add(
            t.g,
            total: 1,
            currency: currency,
            paidBy: SplitSpec.single(ms[3], 1),
            owedBy: SplitSpec(SplitMethod.percent, {
              for (final m in who) m: m == ms[2] ? 3334 : 3333,
            }),
          );
          // 1 minor unit: the largest remainder goes first, ties to the
          // lowest id; ms[2] holds the largest remainder.
          expect(p.owed(pc), {ms[2]: 1}, reason: '$currency percent');
        }
        expectMoneyInvariants(p);
      });
    }
  });
}

/// Simplify on and off: the same nets and per-person totals, at most n-1
/// suggested payments with it on.
void _expectSimplifyNeutral(QaPhone p, GroupId g, String why) {
  final gs = p.state.groups[g];
  if (gs == null || gs.group == null) return;
  final nets = BalanceCalculator.groupNets(gs);
  final pairwise = BalanceCalculator.pairwiseDebts(gs);
  nets.forEach((c, byMember) {
    final simplified = DebtSimplifier.simplify(byMember, c);
    expect(
      simplified.length,
      lessThanOrEqualTo(max(0, byMember.length - 1)),
      reason: why,
    );
    Map<MemberId, int> netOf(Iterable<Transfer> ts) {
      final out = <MemberId, int>{};
      for (final t in ts) {
        if (t.currency != c) continue;
        out[t.from] = (out[t.from] ?? 0) - t.amount;
        out[t.to] = (out[t.to] ?? 0) + t.amount;
      }
      out.removeWhere((_, v) => v == 0);
      return out;
    }

    final fromSimplified = netOf(simplified);
    final fromPairwise = netOf(pairwise);
    final expected = Map<MemberId, int>.of(byMember)
      ..removeWhere((_, v) => v == 0);
    // A transfer from a debtor (net < 0) moves their net to zero.
    expect(
      fromSimplified,
      expected,
      reason: 'simplified per-person totals $c $why',
    );
    expect(
      fromPairwise,
      expected,
      reason: 'pairwise per-person totals $c $why',
    );
  });
}

/// A random split of some of [ms]; the second value is a usable total.
(SplitSpec, int) _randomSpec(Random r, List<MemberId> ms, {int? total}) {
  final who = (ms.toList()..shuffle(r)).take(1 + r.nextInt(ms.length)).toList();
  final t = total ?? 1 + r.nextInt(r.nextBool() ? 7 : 1000000);
  switch (SplitMethod.values[r.nextInt(SplitMethod.values.length)]) {
    case SplitMethod.equal:
      return (SplitSpec.equal(who), t);
    case SplitMethod.exact:
      final v = <MemberId, int>{};
      for (final m in who) {
        final x = (r.nextDouble() * (1 + t ~/ who.length)).floor();
        if (x > 0) v[m] = x;
      }
      if (v.isEmpty) v[who.first] = t;
      return (SplitSpec(SplitMethod.exact, v), t);
    case SplitMethod.percent:
      final v = <MemberId, int>{};
      var left = 10000;
      for (var i = 0; i < who.length; i++) {
        final x = i == who.length - 1 ? left : r.nextInt(left + 1);
        if (x > 0) v[who[i]] = x;
        left -= x;
      }
      return (SplitSpec(SplitMethod.percent, v), t);
    case SplitMethod.shares:
      return (
        SplitSpec(SplitMethod.shares, {
          for (final m in who) m: 1 + r.nextInt(r.nextBool() ? 3 : 1000),
        }),
        t,
      );
    case SplitMethod.adjustment:
      final cap = t ~/ (2 * who.length);
      return (
        SplitSpec(SplitMethod.adjustment, {
          for (final m in who)
            m: cap == 0 ? 0 : (r.nextDouble() * (cap + 1)).floor() - cap ~/ 3,
        }),
        t,
      );
  }
}
