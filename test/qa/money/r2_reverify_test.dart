// QA MONEY round 2: probes around the round-1 fixes (settle currency,
// cycle cancelling with simplify off, duplicate-payment hint, merged me in
// rows, amount reading) on the real Ledger and providers, plus repro tests
// for the defects found in this round (skipped with their ids).
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/format/amount_input.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/expense/split_draft.dart';

import 'amount_parsing_test.dart' show typeInto;
import 'money_harness.dart';
import 'settle_screen_currency_test.dart' show pumpReal, settle;

const int _hour = 3600000;

/// True when [transfers] of one currency contain a directed cycle.
bool _hasCycle(List<Transfer> transfers) {
  final byCur = <String, Map<MemberId, Set<MemberId>>>{};
  for (final t in transfers) {
    byCur
        .putIfAbsent(t.currency, () => {})
        .putIfAbsent(t.from, () => {})
        .add(t.to);
  }
  for (final graph in byCur.values) {
    final state = <MemberId, int>{}; // 1 on path, 2 done
    bool visit(MemberId m) {
      state[m] = 1;
      for (final n in graph[m] ?? const <MemberId>{}) {
        if (state[n] == 1) return true;
        if (state[n] == null && visit(n)) return true;
      }
      state[m] = 2;
      return false;
    }

    for (final m in graph.keys) {
      if (state[m] == null && visit(m)) return true;
    }
  }
  return false;
}

void main() {
  group('MONEY-R1-03 neighbours: cancelCycles with simplify off', () {
    test('random groups: nets kept, no cycle left, no debt grows or flips, '
        'settled groups show nothing', () async {
      for (var seed = 0; seed < 40; seed++) {
        final r = Random(seed);
        final p = await QaPhone.create();
        final t = await p.group([
          'Sam',
          'Priya',
          'Dev',
          'Kai',
        ], simplify: false);
        final g = t.g;
        final ms = t.m.values.toList();
        for (var i = 0; i < 12; i++) {
          final total = 100 + r.nextInt(50000);
          final payer = ms[r.nextInt(ms.length)];
          final owers = [
            for (final m in ms)
              if (r.nextBool()) m,
          ];
          if (owers.isEmpty) owers.add(ms[r.nextInt(ms.length)]);
          await p.add(
            g,
            total: total,
            currency: r.nextInt(3) == 0 ? 'USD' : 'INR',
            paidBy: one(payer, total),
            owedBy: eq(owers),
          );
        }
        final gs = p.gs(g);
        final pairwise = BalanceCalculator.pairwiseDebts(gs);
        final shown = p.transfers(g);
        expectMoneyInvariants(p, reason: 'seed $seed');
        expect(_hasCycle(shown), isFalse, reason: 'seed $seed: $shown');
        for (final s in shown) {
          final same = pairwise.where(
            (x) => x.currency == s.currency && x.from == s.from && x.to == s.to,
          );
          expect(
            same,
            isNotEmpty,
            reason: 'seed $seed: $s is a new or reversed debt',
          );
          expect(
            s.amount,
            lessThanOrEqualTo(same.first.amount),
            reason: 'seed $seed: $s grew',
          );
        }
        // Settle every suggestion, then the group is settled in both views.
        for (final s in shown) {
          await p.pay(
            g,
            from: s.from,
            to: s.to,
            amount: s.amount,
            currency: s.currency,
          );
        }
        expect(p.nets(g), isEmpty, reason: 'seed $seed');
        expect(p.transfers(g), isEmpty, reason: 'seed $seed off');
        expect(
          p.people().where((x) => x.net.isNotEmpty),
          isEmpty,
          reason: 'seed $seed Friends',
        );
        await p.ledger.updateGroup(g, const GroupPatch(simplifyDebts: true));
        await pumpEventQueue();
        expect(p.transfers(g), isEmpty, reason: 'seed $seed on');
        await p.dispose();
      }
    });

    test(
      'the result does not depend on the order expenses were added',
      () async {
        Future<List<Transfer>> run(bool reversed) async {
          final p = await QaPhone.create();
          final t = await p.group(['Sam', 'Priya', 'Dev'], simplify: false);
          final m = t.m;
          final cmds = [
            (m['me']!, m['Sam']!, 4000),
            (m['Sam']!, m['Priya']!, 3000),
            (m['Priya']!, m['me']!, 2500),
            (m['Sam']!, m['Dev']!, 700),
            (m['Dev']!, m['me']!, 700),
          ];
          for (final (payer, ower, x) in reversed ? cmds.reversed : cmds) {
            await p.add(
              t.g,
              total: x,
              paidBy: one(payer, x),
              owedBy: eq([ower]),
            );
          }
          final out = p.transfers(t.g);
          expectMoneyInvariants(p);
          await p.dispose();
          return out;
        }

        expect(await run(true), await run(false));
      },
    );
  });

  group('MONEY-R1-06 neighbours: possible duplicate payments', () {
    late QaPhone p;
    late GroupId g;
    late MemberId me, sam, old;
    setUp(() async {
      p = await QaPhone.create();
      final t = await p.group(['Sam', 'Alex (old)']);
      g = t.g;
      me = t.m['me']!;
      sam = t.m['Sam']!;
      old = t.m['Alex (old)']!;
      await p.add(g, total: 60000, paidBy: one(me, 60000), owedBy: eq([sam]));
    });
    tearDown(() => p.dispose());

    Set<ExpenseId> dups() => possibleDuplicatePayments(p.gs(g));

    test('exactly 24 h apart is a duplicate, 24 h + 1 ms is not', () async {
      final a = await p.pay(g, from: sam, to: me, amount: 30000);
      final b = await p.pay(
        g,
        from: sam,
        to: me,
        amount: 30000,
        dateMs: kBaseMs + 24 * _hour,
      );
      expect(dups(), {a, b});
      final c = await p.pay(
        g,
        from: sam,
        to: me,
        amount: 30000,
        dateMs: kBaseMs + 48 * _hour + 1,
      );
      expect(dups().contains(c), isFalse);
    });

    test('other amount, currency or direction is no duplicate', () async {
      await p.pay(g, from: sam, to: me, amount: 30000);
      await p.pay(g, from: sam, to: me, amount: 29999);
      await p.pay(g, from: sam, to: me, amount: 30000, currency: 'USD');
      await p.pay(g, from: me, to: sam, amount: 30000);
      expect(dups(), isEmpty);
    });

    test('a deleted twin clears the hint; restoring brings it back', () async {
      final a = await p.pay(g, from: sam, to: me, amount: 30000);
      final b = await p.pay(g, from: sam, to: me, amount: 30000);
      expect(dups(), {a, b});
      await p.ledger.deleteExpense(b);
      await pumpEventQueue();
      expect(dups(), isEmpty);
      await p.ledger.restoreExpense(b);
      await pumpEventQueue();
      expect(dups(), {a, b});
    });

    test('a payment by a member later merged into me matches mine', () async {
      final a = await p.pay(g, from: old, to: sam, amount: 5000);
      final b = await p.pay(g, from: me, to: sam, amount: 5000);
      expect(dups(), isEmpty);
      await p.ledger.mergeMembers(g, from: old, into: me);
      await pumpEventQueue();
      expect(dups(), {a, b});
      expectMoneyInvariants(p);
    });
  });

  group('MONEY-R1-01 neighbours: settle from the person screen', () {
    late QaPhone p;
    late GroupId g;
    late MemberId me, sam;

    Future<void> world(WidgetTester tester, {bool opposite = false}) async {
      await tester.runAsync(() async {
        p = await QaPhone.create(home: 'INR');
        final t = await p.group(['Sam']);
        g = t.g;
        me = t.m['me']!;
        sam = t.m['Sam']!;
        // Sam owes me INR 300; USD 20 owed by Sam (or by me when opposite).
        await p.add(
          g,
          total: 60000,
          paidBy: one(me, 60000),
          owedBy: eq([me, sam]),
        );
        final usdPayer = opposite ? sam : me;
        await p.add(
          g,
          total: 4000,
          currency: 'USD',
          paidBy: one(usdPayer, 4000),
          owedBy: eq([me, sam]),
        );
      });
    }

    for (final opposite in [false, true]) {
      testWidgets('group row with two currencies asks which, then records '
          'USD (opposite directions: $opposite)', (tester) async {
        await world(tester, opposite: opposite);
        final c = await pumpReal(tester, p);
        final samPerson = p.gs(g).members[sam]!.personId;
        c.read(routerProvider).go(Routes.person(samPerson));
        await settle(tester);
        await tester.tap(find.text('Trip').first);
        await settle(tester);
        expect(find.text('Who is paying?'), findsOneWidget);
        await tester.tap(
          find.textContaining(MoneyFormat.format(2000, 'USD')).first,
        );
        await settle(tester);
        final label = 'Record ${MoneyFormat.format(2000, 'USD')} payment';
        expect(find.text(label), findsOneWidget);
        await tester.tap(find.text(label));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await settle(tester);
        final pay = p.gs(g).liveExpenses.firstWhere((e) => e.isPayment);
        expect((
          pay.payer,
          pay.receiver,
          pay.money.currency,
          pay.money.total,
        ), opposite ? (me, sam, 'USD', 2000) : (sam, me, 'USD', 2000));
        await tester.runAsync(pumpEventQueue);
        expect(p.nets(g).keys, ['INR'], reason: 'only USD is settled');
        expectMoneyInvariants(p);
        await tester.runAsync(p.dispose);
      });
    }

    testWidgets('person Settle up button opens on the hero currency', (
      tester,
    ) async {
      await world(tester);
      final c = await pumpReal(tester, p);
      final samPerson = p.gs(g).members[sam]!.personId;
      c.read(routerProvider).go(Routes.person(samPerson));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Settle up'));
      await settle(tester);
      expect(
        find.text('Record ${MoneyFormat.format(30000, 'INR')} payment'),
        findsOneWidget,
      );
      await tester.runAsync(p.dispose);
    });
  });

  group('MONEY-R1-07 neighbours: payments of a member merged into me', () {
    testWidgets('a payment by my merged duplicate reads "You paid"', (
      tester,
    ) async {
      late QaPhone p;
      late GroupId g;
      await tester.runAsync(() async {
        p = await QaPhone.create(home: 'INR');
        final t = await p.group(['Sam', 'Alex (old)']);
        g = t.g;
        final old = t.m['Alex (old)']!;
        await p.add(
          g,
          total: 60000,
          paidBy: one(t.m['Sam']!, 60000),
          owedBy: eq([old, t.m['Sam']!]),
        );
        await p.pay(g, from: old, to: t.m['Sam']!, amount: 30000);
        await p.ledger.mergeMembers(g, from: old, into: t.m['me']!);
        await pumpEventQueue();
      });
      expect(p.nets(g), isEmpty);
      final c = await pumpReal(tester, p);
      c.read(routerProvider).go(Routes.group(g));
      await settle(tester);
      expect(find.textContaining('You paid Sam'), findsWidgets);
      await tester.runAsync(p.dispose);
    });
  });

  group('MONEY-R1-02/04 neighbours: amount reading that works', () {
    final eur = Currencies.of('EUR');
    final inr = Currencies.of('INR');
    final kwd = Currencies.of('KWD');
    test('either convention, spaces, apostrophes, lakh', () {
      expect(parseAmountInput('1.234,50', eur), 123450);
      expect(parseAmountInput('1,234.50', eur), 123450);
      expect(parseAmountInput('1 234,50', eur), 123450);
      expect(parseAmountInput("1'234.50", eur), 123450);
      expect(parseAmountInput('1.234.567,89', eur), 123456789);
      expect(parseAmountInput('1,23,456.00', inr), 12345600);
      expect(parseAmountInput('12.345', kwd), 12345);
      expect(parseAmountInput('12,5', eur), 1250);
    });
    test('unreadable text is refused, not counted as less', () {
      for (final s in ['1.23,45', '1..2', '1,,2', '1,2,3', '1.2.3']) {
        expect(parseAmountInput(s, eur), isNull, reason: s);
      }
      expect(parseAmountInput('1.234', eur), isNull);
      expect(parseAmountInput('12.345', inr), isNull);
    });
    test('split fields: grouped adjustment and too-many-decimals flagged', () {
      expect(parseSignedMinor('1,000', inr), 100000);
      expect(parseSignedMinor('−1.000,50', eur), -100050);
      expect(parsePercent('33,33'), 3333);
      expect(parseSignedMinor('12.345', inr), isNull);
    });
    testWidgets('typed European 1.234.567,89 and pasted 1.234,50', (t) async {
      expect(await typeInto(t, 'EUR', '1.234.567,89'), 123456789);
      expect(await typeInto(t, 'EUR', '1.234,50', paste: true), 123450);
      expect(await typeInto(t, 'USD', '1,234.50'), 123450);
    });
  });

  // ------------------------------------------------ round-2 findings --

  group('QA MONEY-R2-01', () {
    testWidgets(
      'QA MONEY-R2-01: typing a comma-grouped amount with two commas is '
      'never read as a 1000x smaller amount',
      (t) async {
        // The field itself shows "1,234,567"; typing that, key by key,
        // must give 1,234,567 (or be refused), never 1.23.
        expect(await typeInto(t, 'USD', '1,234,567'), 123456700);
        expect(await typeInto(t, 'INR', '1,00,000'), 10000000);
        expect(await typeInto(t, 'JPY', '1,000,000'), 1000000);
      },
    );
  });

  group('QA MONEY-R2-02', () {
    testWidgets(
      'QA MONEY-R2-02: a pasted "Rs. 500" is never 0.50',
      (t) async {
        for (final s in ['Rs. 500', 'Rs.500', 'approx. 300']) {
          final v = await typeInto(t, 'INR', s, paste: true);
          expect(v, anyOf(isNull, greaterThanOrEqualTo(30000)), reason: s);
        }
      },
    );
  });

  group('QA MONEY-R2-03', () {
    final kwd = Currencies.of('KWD');
    final tnd = Currencies.of('TND');
    final eur = Currencies.of('EUR');
    test(
      'QA MONEY-R2-03: "0,500" is half a dinar, never 500 dinars',
      () {
        expect(parseAmountInput('0,500', kwd), anyOf(isNull, 500));
        expect(parseAmountInput('0,250', tnd), anyOf(isNull, 250));
        expect(parseSignedMinor('0,500', kwd), anyOf(isNull, 500));
        // A leading zero group is never thousands grouping in any currency.
        expect(parseAmountInput('0,500', eur), isNull);
        expect(parseAmountInput('00,123', eur), isNull);
      },
    );
    testWidgets(
      'QA MONEY-R2-03: the amount field reads "0,500" KWD as 0.500',
      (t) async {
        expect(await typeInto(t, 'KWD', '0,500'), anyOf(isNull, 500));
        expect(
          await typeInto(t, 'KWD', '0,500', paste: true),
          anyOf(isNull, 500),
        );
      },
    );
  });

  group('QA MONEY-R2-04', () {
    testWidgets(
      'QA MONEY-R2-04: a decimal comma the field already shows as the '
      'decimal point stays one when a third decimal is typed',
      (t) async {
        // After "1,25" the field shows "1.25"; one more digit must not turn
        // it into one thousand two hundred and fifty.
        expect(await typeInto(t, 'TND', '1,250'), 1250);
        // KWD writes a dot, so its "12,345" is twelve thousand three hundred
        // and forty-five wherever it is entered (one reading per currency,
        // R3-06; QA MONEY-R3-03 reopened), as USD "12,345" is.
        expect(
          await typeInto(t, 'KWD', '12,345'),
          parseAmountInput('12,345', Currencies.of('KWD')),
        );
        // Two-decimal currency: a stray third digit is cut or refused, never
        // multiplies the amount by a thousand.
        expect(await typeInto(t, 'EUR', '12,500'), anyOf(isNull, 1250));
      },
    );
  });

  group('QA MONEY-R2-05', () {
    testWidgets(
      'QA MONEY-R2-05: pasting more decimals than the currency has is not '
      'silently cut',
      (t) async {
        // Split fields refuse these as unreadable; the big amount field
        // keeps "1.23" / "12.34" without a word.
        expect(await typeInto(t, 'EUR', '1.234', paste: true), isNot(123));
        expect(await typeInto(t, 'INR', '12.345', paste: true), isNot(1234));
      },
    );
  });
}
