// QA MONEY round 24: final regression sweep on the integrated build.
//
// Fresh probes over the real Ledger(MemoryOpStore) and providers:
// - every split method, payer and ower side, against an independent BigInt
//   largest-remainder oracle, with member ids that do not follow creation
//   order and the spec maps inserted in a random order (ties go to the
//   lowest member id whatever the order), invalid specs refused;
// - the CSV export of a seeded random ledger (merges, removals, payments,
//   deletes and restores, three currencies, risky text) read back with an
//   RFC 4180 reader and checked against groupNets column by column;
// - settling every suggested payment, in a random order and amount
//   pattern, empties every balance with simplify on and off;
// - the Settle up "What changes" preview against the balances the ledger
//   shows once the payment is recorded.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/csv_export.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/settle/settle_preview.dart';
import 'package:settle_up/ui/widgets/settle_controls.dart';

import 'csv_ledger_test.dart' show minorOf, readCsv;
import 'money_harness.dart';
import 'settle_screen_currency_test.dart' show pumpReal, settle;

/// Random UUID-shaped ids, so member ids do not follow creation order.
List<String> _randomIds(Random r, int n) {
  String hex(int len) =>
      List.generate(len, (_) => r.nextInt(16).toRadixString(16)).join();
  final out = <String>{};
  while (out.length < n) {
    out.add('${hex(8)}-${hex(4)}-7${hex(3)}-8${hex(3)}-${hex(12)}');
  }
  return out.toList();
}

/// Independent largest-remainder apportionment in BigInt: floor shares,
/// then +1 by largest remainder, ties by id ascending. Zero shares omitted.
Map<MemberId, int> _apportion(int total, Map<MemberId, int> weights) {
  final ids = weights.keys.toList()..sort();
  final w = ids.fold(BigInt.zero, (a, id) => a + BigInt.from(weights[id]!));
  final t = BigInt.from(total);
  final q = <MemberId, BigInt>{};
  final rem = <MemberId, BigInt>{};
  var given = BigInt.zero;
  for (final id in ids) {
    final p = t * BigInt.from(weights[id]!);
    q[id] = p ~/ w;
    rem[id] = p % w;
    given += q[id]!;
  }
  var left = (t - given).toInt();
  final order = [...ids]
    ..sort((a, b) {
      final c = rem[b]!.compareTo(rem[a]!);
      return c != 0 ? c : a.compareTo(b);
    });
  for (final id in order) {
    if (left == 0) break;
    q[id] = q[id]! + BigInt.one;
    left--;
  }
  return {
    for (final id in ids)
      if (q[id]! > BigInt.zero) id: q[id]!.toInt(),
  };
}

/// What [spec] must give for [total], or null when it must be refused.
Map<MemberId, int>? _oracle(int total, SplitSpec spec) {
  final v = spec.values;
  if (v.isEmpty) return null;
  switch (spec.method) {
    case SplitMethod.equal:
      return _apportion(total, {for (final m in v.keys) m: 1});
    case SplitMethod.exact:
      if (v.values.any((x) => x < 0)) return null;
      if (v.values.fold<int>(0, (a, b) => a + b) != total) return null;
      return {
        for (final m in v.keys.toList()..sort())
          if (v[m] != 0) m: v[m]!,
      };
    case SplitMethod.percent:
      if (v.values.any((x) => x < 0)) return null;
      if (v.values.fold<int>(0, (a, b) => a + b) != 10000) return null;
      return _apportion(total, v);
    case SplitMethod.shares:
      if (v.values.any((x) => x < 1)) return null;
      return _apportion(total, v);
    case SplitMethod.adjustment:
      final rest = total - v.values.fold<int>(0, (a, b) => a + b);
      if (rest < 0) return null;
      final base = _apportion(rest, {for (final m in v.keys) m: 1});
      final out = <MemberId, int>{};
      for (final m in v.keys.toList()..sort()) {
        final s = (base[m] ?? 0) + v[m]!;
        if (s < 0) return null;
        if (s > 0) out[m] = s;
      }
      return out;
  }
}

/// [values] re-inserted in a random order (same content).
Map<MemberId, int> _shuffled(Random r, Map<MemberId, int> values) {
  final keys = values.keys.toList()..shuffle(r);
  return {for (final k in keys) k: values[k]!};
}

/// Uniform-ish in [0, n) for n up to 2^62 (Random.nextInt stops at 2^32).
int _below(Random r, int n) => n <= 1 << 31
    ? r.nextInt(n)
    : ((r.nextInt(1 << 31) << 31) | r.nextInt(1 << 31)) % n;

/// A random spec over [members] (sometimes invalid on purpose).
SplitSpec _randomSpec(Random r, int total, List<MemberId> members) {
  final n = 1 + r.nextInt(members.length);
  final who = ([...members]..shuffle(r)).take(n).toList();
  final method = SplitMethod.values[r.nextInt(SplitMethod.values.length)];
  switch (method) {
    case SplitMethod.equal:
      return SplitSpec(method, {for (final m in who) m: 1});
    case SplitMethod.exact:
      final out = <MemberId, int>{};
      var left = total;
      for (var i = 0; i < who.length; i++) {
        final x = i == who.length - 1 ? left : _below(r, left + 1);
        out[who[i]] = x;
        left -= x;
      }
      if (r.nextInt(10) == 0) out[who.first] = out[who.first]! + 1; // bad
      return SplitSpec(method, out);
    case SplitMethod.percent:
      final out = <MemberId, int>{};
      var left = 10000;
      for (var i = 0; i < who.length; i++) {
        final x = i == who.length - 1 ? left : _below(r, left + 1);
        out[who[i]] = x;
        left -= x;
      }
      if (r.nextInt(10) == 0) out[who.first] = out[who.first]! - 1; // bad
      return SplitSpec(method, out);
    case SplitMethod.shares:
      return SplitSpec(method, {
        for (final m in who)
          m: switch (r.nextInt(6)) {
            0 => 1000,
            1 => 1,
            2 => r.nextInt(20) == 0 ? 0 : 3, // 0 is refused
            _ => 1 + r.nextInt(9),
          },
      });
    case SplitMethod.adjustment:
      final span = max(1, total ~/ max(1, who.length));
      return SplitSpec(method, {
        for (final m in who)
          m: switch (r.nextInt(4)) {
            0 => 0,
            1 => -_below(r, span ~/ 2 + 1),
            _ => _below(r, span + 1),
          },
      });
  }
}

const _texts = [
  'Dinner',
  '=SUM(A1:A9)',
  '+91 cab',
  '-5 off',
  '@home',
  'a, b and c',
  'say "hi"',
  'two\nlines',
  'tab\tinside',
  '− minus sign',
];

void main() {
  for (final seed in [2401, 2402, 2403, 2404, 2405, 2406]) {
    test('every split method matches the BigInt oracle via the Ledger, '
        'seed $seed', () async {
      final r = Random(seed);
      final p = await QaPhone.create(prefix: 'bbbbbbbb');
      addTearDown(p.dispose);
      p.ids.queue(_randomIds(r, 400));
      final count = 1 + r.nextInt(7);
      final names = [for (var i = 1; i <= count; i++) 'P$i'];
      final currency = ['JPY', 'KWD', 'INR'][seed % 3];
      final t = await p.group(names, currency: currency);
      final members = t.m.values.toList();
      for (var i = 0; i < 60; i++) {
        final total = switch (r.nextInt(6)) {
          0 => 1 + r.nextInt(3),
          1 => Money.maxMinor - r.nextInt(3),
          2 => 1 + r.nextInt(100),
          _ => 1 + r.nextInt(10000000),
        };
        final paidBy = r.nextInt(3) == 0
            ? _randomSpec(r, total, members)
            : SplitSpec.single(members[r.nextInt(members.length)], total);
        final owedBy = _randomSpec(r, total, members);
        final wantPaid = _oracle(total, paidBy);
        final wantOwed = _oracle(total, owedBy);
        final why =
            'seed $seed #$i total $total '
            'paid ${paidBy.method.name} ${paidBy.values} '
            'owed ${owedBy.method.name} ${owedBy.values}';
        if (wantPaid == null || wantOwed == null) {
          await expectLater(
            p.add(
              t.g,
              total: total,
              currency: currency,
              paidBy: paidBy,
              owedBy: owedBy,
            ),
            throwsA(isA<LedgerException>()),
            reason: 'refused: $why',
          );
          continue;
        }
        final id = await p.add(
          t.g,
          total: total,
          currency: currency,
          paidBy: paidBy,
          owedBy: owedBy,
        );
        expect(p.paid(id), wantPaid, reason: 'paid $why');
        expect(p.owed(id), wantOwed, reason: 'owed $why');
        // The same specs inserted in another order give the same shares.
        final again = await p.add(
          t.g,
          total: total,
          currency: currency,
          paidBy: SplitSpec(paidBy.method, _shuffled(r, paidBy.values)),
          owedBy: SplitSpec(owedBy.method, _shuffled(r, owedBy.values)),
        );
        expect(p.paid(again), wantPaid, reason: 'paid reordered $why');
        expect(p.owed(again), wantOwed, reason: 'owed reordered $why');
        if (r.nextBool()) await p.ledger.deleteExpense(again);
        await pumpEventQueue();
        expectMoneyInvariants(p, reason: why);
      }
    });
  }

  test('50 members at Money.maxMinor, all five methods, nets exact', () async {
    final r = Random(2450);
    final p = await QaPhone.create(prefix: 'cccccccc');
    addTearDown(p.dispose);
    p.ids.queue(_randomIds(r, 400));
    final t = await p.group([for (var i = 1; i < 50; i++) 'M$i']);
    final ms = t.m.values.toList();
    expect(ms, hasLength(50));
    const total = Money.maxMinor;
    final specs = [
      eq(ms),
      spec(SplitMethod.shares, {for (final m in ms) m: 1 + r.nextInt(1000)}),
      spec(SplitMethod.percent, {
        for (var i = 0; i < 50; i++) ms[i]: i < 49 ? 200 : 200,
      }),
      spec(SplitMethod.adjustment, {
        for (var i = 0; i < 50; i++) ms[i]: i == 0 ? -1999999999 : 0,
      }),
    ];
    for (final s in specs) {
      final id = await p.add(
        t.g,
        total: total,
        paidBy: spec(SplitMethod.equal, {for (final m in ms) m: 1}),
        owedBy: s,
      );
      expect(p.owed(id), _oracle(total, s), reason: s.method.name);
      expect(p.paid(id), _oracle(total, eq(ms)));
      expectMoneyInvariants(p, reason: s.method.name);
    }
  });

  for (final seed in [2411, 2412, 2413, 2414]) {
    test(
      'CSV of a random ledger reads back to groupNets, seed $seed',
      () async {
        final r = Random(seed);
        final p = await QaPhone.create(prefix: 'dddddddd');
        addTearDown(p.dispose);
        p.ids.queue(_randomIds(r, 2000));
        final t = await p.group([
          'Sam',
          '-Dash',
          '=Eq',
          'Comma, Jr',
          'Say "Q"',
        ], simplify: r.nextBool());
        final g = t.g;
        final ids = <ExpenseId>[];
        const curs = ['INR', 'JPY', 'KWD'];
        for (var i = 0; i < 70; i++) {
          final gs = p.gs(g);
          final active = gs.activeMembers.map((m) => m.id).toList();
          final cur = curs[r.nextInt(3)];
          final k = r.nextInt(12);
          try {
            if (k < 6) {
              final total = 1 + r.nextInt(500000);
              final owedBy = _randomSpec(r, total, active);
              if (_oracle(total, owedBy) == null) continue;
              p.tick();
              ids.add(
                await p.ledger.addExpense(
                  ExpenseDraft(
                    groupId: g,
                    description: _texts[r.nextInt(_texts.length)],
                    total: total,
                    currency: cur,
                    paidBy: one(active[r.nextInt(active.length)], total),
                    owedBy: owedBy,
                    category: 'food.dining',
                    date: utcFromMillis(kBaseMs + r.nextInt(30) * 86400000),
                  ),
                ),
              );
            } else if (k < 8 && active.length > 1) {
              final from = active[r.nextInt(active.length)];
              final to = (active.toList()
                ..remove(from))[r.nextInt(active.length - 1)];
              ids.add(
                await p.pay(
                  g,
                  from: from,
                  to: to,
                  amount: 1 + r.nextInt(90000),
                  currency: cur,
                  dateMs: kBaseMs + r.nextInt(30) * 86400000,
                ),
              );
            } else if (k == 8 && ids.isNotEmpty) {
              p.tick();
              await p.ledger.deleteExpense(ids[r.nextInt(ids.length)]);
            } else if (k == 9 && ids.isNotEmpty) {
              p.tick();
              await p.ledger.restoreExpense(ids[r.nextInt(ids.length)]);
            } else if (k == 10 && active.length > 3) {
              final others = active.where((m) => m != t.m['me']).toList()
                ..shuffle(r);
              p.tick();
              await p.ledger.mergeMembers(g, from: others[0], into: others[1]);
            } else if (k == 11 && active.length > 3) {
              final others = active.where((m) => m != t.m['me']).toList();
              p.tick();
              await p.ledger.removeMember(g, others[r.nextInt(others.length)]);
            }
          } on LedgerException {
            // A refused random command is fine; the money must stay right.
          }
          await pumpEventQueue();
        }
        expectMoneyInvariants(p, reason: 'seed $seed');
        final gs = p.gs(g);
        final csv = CsvExport.group(gs);
        final rows = readCsv(csv);
        final header = rows.first;
        expect(header.take(5), [
          'Date',
          'Description',
          'Category',
          'Cost',
          'Currency',
        ]);
        String shown(String s) =>
            s.isNotEmpty && '=+-@\t\r'.contains(s[0]) ? "'$s" : s;
        final active = gs.activeMembers;
        final cols = header.sublist(5);
        expect(cols.take(active.length), [
          for (final m in active) shown(m.displayName),
        ], reason: 'active members first, in their list order');
        // Map every column back to a member (the extra ones are removed
        // members with money in an exported row).
        final colIds = [for (final m in active) m.id];
        final extra = gs.members.values
            .where((m) => !active.contains(m) && gs.resolve(m.id) == m.id)
            .toList();
        for (final name in cols.skip(active.length)) {
          final m = extra.where((x) => shown(x.displayName) == name).toList();
          expect(m, isNotEmpty, reason: 'extra column $name is a member');
          colIds.add(m.first.id);
        }
        final live = gs.liveExpenses
          ..sort((a, b) {
            final c = a.date.compareTo(b.date);
            return c != 0 ? c : a.id.compareTo(b.id);
          });
        expect(rows.length - 1, live.length, reason: 'deleted rows excluded');
        final sums = <String, Map<MemberId, int>>{};
        for (var i = 0; i < live.length; i++) {
          final e = live[i];
          final row = rows[i + 1];
          final digits = Currencies.of(e.money.currency).minorDigits;
          expect(row, hasLength(header.length));
          expect(row[4], e.money.currency);
          expect(minorOf(row[3], digits), e.money.total);
          expect(row[2], e.isPayment ? 'Payment' : isNot('Payment'));
          if (e.description.isNotEmpty) {
            expect(row[1], shown(e.description), reason: 'description cell');
          } else {
            String name(MemberId id) => gs.members[gs.resolve(id)]!.displayName;
            expect(
              row[1],
              shown('${name(e.payer)} paid ${name(e.receiver)}'),
              reason: 'payment description cell',
            );
          }
          var rowSum = 0;
          for (var c = 0; c < colIds.length; c++) {
            final v = minorOf(row[5 + c], digits);
            rowSum += v;
            final s = sums.putIfAbsent(e.money.currency, () => {});
            s[colIds[c]] = (s[colIds[c]] ?? 0) + v;
          }
          expect(rowSum, 0, reason: 'row $i member columns sum to zero');
        }
        for (final s in sums.values) {
          s.removeWhere((_, v) => v == 0);
        }
        sums.removeWhere((_, v) => v.isEmpty);
        expect(sums, p.nets(g), reason: 'CSV column totals == groupNets');
      },
    );
  }

  for (final simplify in [true, false]) {
    for (final seed in [2421, 2422, 2423]) {
      test('paying every suggestion settles the group, simplify $simplify, '
          'seed $seed', () async {
        final r = Random(seed);
        final p = await QaPhone.create(prefix: 'eeeeeeee');
        addTearDown(p.dispose);
        p.ids.queue(_randomIds(r, 600));
        final t = await p.group([
          'Sam',
          'Priya',
          'Dev',
          'Kai',
        ], simplify: simplify);
        final ms = t.m.values.toList();
        for (var i = 0; i < 25; i++) {
          final total = 1 + r.nextInt(400000);
          final cur = ['INR', 'JPY', 'KWD'][r.nextInt(3)];
          final owedBy = _randomSpec(r, total, ms);
          if (_oracle(total, owedBy) == null) continue;
          final paidBy = r.nextBool()
              ? one(ms[r.nextInt(ms.length)], total)
              : _randomSpec(r, total, ms);
          if (_oracle(total, paidBy) == null) continue;
          await p.add(
            t.g,
            total: total,
            currency: cur,
            paidBy: paidBy,
            owedBy: owedBy,
          );
        }
        expectMoneyInvariants(p);
        // Pay suggestions until none are left: sometimes in two parts,
        // sometimes over by a bit (paid back by the suggestion it makes).
        for (var round = 0; round < 200; round++) {
          final ts = p.transfers(t.g);
          if (ts.isEmpty) break;
          final tr = ts[r.nextInt(ts.length)];
          final amount = switch (r.nextInt(4)) {
            0 when tr.amount > 1 => 1 + r.nextInt(tr.amount - 1),
            1 => tr.amount + 1 + r.nextInt(50),
            _ => tr.amount,
          };
          await p.pay(
            t.g,
            from: tr.from,
            to: tr.to,
            amount: amount,
            currency: tr.currency,
          );
          expectMoneyInvariants(p, reason: 'round $round');
        }
        expect(p.transfers(t.g), isEmpty);
        expect(p.nets(t.g), isEmpty);
        expect(p.people().every((x) => x.isSettled), isTrue);
        expect(p.overall().net, isEmpty);
      });
    }
  }

  // ------------------------------------------------------- MONEY-R24-01 --

  /// Me, Sam, Priya and Dev. I owe Sam 60 and Priya 10, Dev owes Priya 30
  /// (Sam paid 60 for me; Priya paid 40, 10 mine and 30 Dev's).
  Future<({QaPhone p, GroupId g, MemberId me, MemberId sam, MemberId priya})>
  fourWay(bool simplify) async {
    final p = await QaPhone.create();
    final t = await p.group(['Sam', 'Priya', 'Dev'], simplify: simplify);
    final me = t.m['me']!, sam = t.m['Sam']!, priya = t.m['Priya']!;
    final dev = t.m['Dev']!;
    await p.add(
      t.g,
      total: 6000,
      paidBy: one(sam, 6000),
      owedBy: one(me, 6000),
    );
    await p.add(
      t.g,
      total: 4000,
      paidBy: one(priya, 4000),
      owedBy: spec(SplitMethod.exact, {me: 1000, dev: 3000}),
    );
    return (p: p, g: t.g, me: me, sam: sam, priya: priya);
  }

  /// My balance with [other] in the group as the Group and Settle up
  /// screens show it (+ they owe me), from the suggested payments.
  int pairNet(QaPhone p, GroupId g, MemberId me, MemberId other) {
    var v = 0;
    for (final t in p.transfers(g)) {
      if (t.from == me && t.to == other) v -= t.amount;
      if (t.to == me && t.from == other) v += t.amount;
    }
    return v;
  }

  testWidgets(
    'QA MONEY-R24-01: a part payment previews the balance with that person '
    'the ledger then shows (simplify on)',
    (tester) async {
      late ({QaPhone p, GroupId g, MemberId me, MemberId sam, MemberId priya})
      w;
      await tester.runAsync(() async => w = await fourWay(true));
      final p = w.p;
      expect(pairNet(p, w.g, w.me, w.sam), -6000);
      expect(pairNet(p, w.g, w.me, w.priya), -1000);
      final c = await pumpReal(tester, p);
      c
          .read(routerProvider)
          .go(
            Routes.settle(groupId: w.g, from: w.me, to: w.sam, currency: 'INR'),
          );
      await settle(tester);
      // Pay part of it: 25 of the 60.
      await tester.tap(find.text('Pay part of it'));
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, '25');
      await settle(tester);
      await tester.tap(find.text('Done'));
      await settle(tester);
      final table = tester.widget<BeforeAfterTable>(
        find.byType(BeforeAfterTable),
      );
      final previewPair = table.entries[0].after.minor;
      final previewSam = table.entries[1].after.minor;
      // The ledger reroutes: I pay Priya 40, Dev pays Sam 30, I pay Sam 5.
      expect(previewPair, -500, reason: 'the screen previews I owe Sam 5');
      // My balance with Priya moves too, and the screen says so.
      expect(
        table.entries.map((e) => e.title),
        containsAllInOrder(['You and Sam', 'Sam overall', 'You and Priya']),
      );
      final priyaRow = table.entries.firstWhere(
        (e) => e.title == 'You and Priya',
      );
      expect((priyaRow.now.minor, priyaRow.after.minor), (-1000, -4000));
      expect(table.entries.last.title, 'Your overall');
      final frozen = [for (final e in table.entries) e.after.minor];
      await tester.tap(find.text('Record ₹25 payment'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // The confirmation keeps the previewed after-values (the ledger's,
      // checked below) while the recorded animation plays.
      final done = tester.widget<BeforeAfterTable>(
        find.byType(BeforeAfterTable).last,
      );
      expect([for (final e in done.entries) e.after.minor], frozen);
      expect([for (final e in done.entries) e.now.minor], frozen);
      await settle(tester);
      await tester.runAsync(pumpEventQueue);
      final pay = p.gs(w.g).liveExpenses.firstWhere((e) => e.isPayment);
      expect((pay.payer, pay.receiver, pay.money.total), (w.me, w.sam, 2500));
      // What the Group and Friends screens show now.
      final samPerson = p.gs(w.g).members[w.sam]!.personId;
      final samNet = p
          .people()
          .firstWhere((x) => x.personId == samPerson)
          .net['INR'];
      expect(
        pairNet(p, w.g, w.me, w.sam),
        previewPair,
        reason: '"You and Sam" after the payment, as previewed',
      );
      expect(samNet, previewSam, reason: '"Sam overall" as previewed');
      await tester.runAsync(p.dispose);
    },
  );

  /// The Settle up preview of [from] paying [to] [amount] (INR) against
  /// the balances the ledger shows once that payment is recorded: every
  /// pair with me in the group, every person overall and my overall.
  Future<void> expectPreviewMatches(
    QaPhone p,
    GroupId g, {
    required MemberId from,
    required MemberId to,
    required int amount,
    String currency = 'INR',
    String reason = '',
  }) async {
    final me = p.gs(g).memberForPerson(p.me)!.id;
    final preview = SettlePreview.of(
      p.state,
      p.me,
      groupId: g,
      from: from,
      to: to,
      amount: amount,
      currency: currency,
      date: DateTime.utc(2026, 11, 12),
    );
    final members = p.gs(g).activeMembers.map((m) => m.id).toList();
    final predicted = {
      for (final m in members)
        if (m != me) m: preview.pairAfter(me, m),
    };
    final pair = preview.pairAfter(from, to);
    final people = {
      for (final x in preview.peopleAfter) x.personId: x.net[currency] ?? 0,
    };
    final overall = preview.overallAfter;
    await p.pay(g, from: from, to: to, amount: amount, currency: currency);
    int net(MemberId a, MemberId b) {
      var v = 0;
      for (final t in p.transfers(g)) {
        if (t.currency != currency) continue;
        if (t.from == a && t.to == b) v -= t.amount;
        if (t.to == a && t.from == b) v += t.amount;
      }
      return v;
    }

    for (final m in predicted.keys) {
      expect(net(me, m), predicted[m], reason: '$reason you and $m');
    }
    expect(net(from, to), pair, reason: '$reason $from and $to');
    expect(
      {for (final x in p.people()) x.personId: x.net[currency] ?? 0},
      people,
      reason: '$reason people overall',
    );
    expect(p.overall().net[currency] ?? 0, overall, reason: '$reason overall');
  }

  test('QA MONEY-R24-01: simplify on, a part payment moves the balance with '
      'Sam and with Priya as the screen previews', () async {
    final w = await fourWay(true);
    final p = w.p;
    addTearDown(p.dispose);
    final preview = SettlePreview.of(
      p.state,
      p.me,
      groupId: w.g,
      from: w.me,
      to: w.sam,
      amount: 2500,
      currency: 'INR',
      date: DateTime.utc(2026, 11, 12),
    );
    // Not now + amount: the suggestions are recomputed and route the
    // debts differently (I pay Priya 40, Dev pays Sam 30, I pay Sam 5).
    expect(preview.pairAfter(w.me, w.sam), -500);
    expect(preview.pairAfter(w.me, w.priya), -4000);
    expect(preview.othersChanged(w.me, {w.me, w.sam}), [w.priya]);
    await expectPreviewMatches(p, w.g, from: w.me, to: w.sam, amount: 2500);
    expect(pairNet(p, w.g, w.me, w.sam), -500, reason: 'You and Sam');
    expect(pairNet(p, w.g, w.me, w.priya), -4000, reason: 'You and Priya');
  });

  test('QA MONEY-R24-01: simplify off, an over-payment that closes a cycle '
      'previews Sam settled and Priya owing me the extra', () async {
    final p = await QaPhone.create();
    addTearDown(p.dispose);
    final t = await p.group(['Sam', 'Priya'], simplify: false);
    final me = t.m['me']!, sam = t.m['Sam']!, priya = t.m['Priya']!;
    // Raw debts: I owe Sam 60, Sam owes Priya 30, Priya owes me 20. The
    // cycle is cancelled: I owe Sam 40, Sam owes Priya 10.
    await p.add(
      t.g,
      total: 6000,
      paidBy: one(sam, 6000),
      owedBy: one(me, 6000),
    );
    await p.add(
      t.g,
      total: 3000,
      paidBy: one(priya, 3000),
      owedBy: one(sam, 3000),
    );
    await p.add(
      t.g,
      total: 2000,
      paidBy: one(me, 2000),
      owedBy: one(priya, 2000),
    );
    expect(pairNet(p, t.g, me, sam), -4000);
    expect(pairNet(p, t.g, me, priya), 0);
    final preview = SettlePreview.of(
      p.state,
      p.me,
      groupId: t.g,
      from: me,
      to: sam,
      amount: 5000,
      currency: 'INR',
      date: DateTime.utc(2026, 11, 12),
    );
    expect(preview.pairAfter(me, sam), 0);
    expect(preview.pairAfter(me, priya), 1000);
    await expectPreviewMatches(p, t.g, from: me, to: sam, amount: 5000);
    expect(pairNet(p, t.g, me, sam), 0, reason: 'Sam settled with me');
    expect(pairNet(p, t.g, me, priya), 1000, reason: 'Priya owes me 10');
  });

  // Property: on seeded random groups (simplify on and off, three
  // currencies, merges of who paid and who owed), every payment the
  // screen can record - a suggestion in full, a part of it, more than it,
  // and a payment between two other people - previews exactly the
  // balances the ledger then shows.
  for (final simplify in [true, false]) {
    for (var seed = 1; seed <= 6; seed++) {
      test(
        'MONEY-R24-01 property (simplify ${simplify ? 'on' : 'off'}, seed '
        '$seed): the Settle up preview is what the ledger shows after',
        () async {
          final r = Random(seed * 7919 + (simplify ? 1 : 0));
          final p = await QaPhone.create(prefix: 'dddddddd');
          addTearDown(p.dispose);
          p.ids.queue(_randomIds(r, 400));
          final t = await p.group([
            'Sam',
            'Priya',
            'Dev',
            'Kai',
          ], simplify: simplify);
          final ms = t.m.values.toList();
          for (var i = 0; i < 8; i++) {
            final total = 100 + r.nextInt(20000);
            final cur = ['INR', 'JPY', 'KWD'][r.nextInt(3)];
            final payer = ms[r.nextInt(ms.length)];
            final owers = ([...ms]..shuffle(r)).take(1 + r.nextInt(4));
            await p.add(
              t.g,
              total: total,
              currency: cur,
              paidBy: one(payer, total),
              owedBy: SplitSpec.equal(owers),
            );
          }
          for (var round = 0; round < 12; round++) {
            final ts = p.transfers(t.g);
            final MemberId from, to;
            final String cur;
            final int amount;
            if (ts.isEmpty || r.nextInt(5) == 0) {
              from = ms[r.nextInt(ms.length)];
              to = ms.where((m) => m != from).toList()[r.nextInt(3)];
              cur = ['INR', 'JPY', 'KWD'][r.nextInt(3)];
              amount = 1 + r.nextInt(5000);
            } else {
              final tr = ts[r.nextInt(ts.length)];
              from = tr.from;
              to = tr.to;
              cur = tr.currency;
              amount = switch (r.nextInt(3)) {
                0 when tr.amount > 1 => 1 + r.nextInt(tr.amount - 1),
                1 => tr.amount + 1 + r.nextInt(3000),
                _ => tr.amount,
              };
            }
            await expectPreviewMatches(
              p,
              t.g,
              from: from,
              to: to,
              amount: amount,
              currency: cur,
              reason: 'round $round',
            );
          }
        },
      );
    }
  }

  /// Opens Settle up for [from] -> [to] (INR) and enters [amount] (major
  /// units) through "Pay part of it"; returns the screen's texts.
  Future<List<String>> settleTexts(
    WidgetTester tester,
    QaPhone p,
    GroupId g,
    MemberId from,
    MemberId to,
    String amount,
  ) async {
    final c = await pumpReal(tester, p);
    c
        .read(routerProvider)
        .go(Routes.settle(groupId: g, from: from, to: to, currency: 'INR'));
    await settle(tester);
    await tester.tap(find.text('Pay part of it'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, amount);
    await settle(tester);
    await tester.tap(find.text('Done'));
    await settle(tester);
    return [
      for (final e in find.byType(Text).evaluate())
        if ((e.widget as Text).data case final String d) d,
    ];
  }

  testWidgets('MONEY-R24-01: simplify off, paying more than the balance '
      'when the extra closes a cycle does not say the one paid will owe '
      'it back', (tester) async {
    late QaPhone p;
    late GroupId g;
    late MemberId me, sam, priya;
    await tester.runAsync(() async {
      p = await QaPhone.create();
      final t = await p.group(['Sam', 'Priya'], simplify: false);
      g = t.g;
      me = t.m['me']!;
      sam = t.m['Sam']!;
      priya = t.m['Priya']!;
      await p.add(
        g,
        total: 6000,
        paidBy: one(sam, 6000),
        owedBy: one(me, 6000),
      );
      await p.add(
        g,
        total: 3000,
        paidBy: one(priya, 3000),
        owedBy: one(sam, 3000),
      );
      await p.add(
        g,
        total: 2000,
        paidBy: one(me, 2000),
        owedBy: one(priya, 2000),
      );
    });
    final texts = await settleTexts(tester, p, g, me, sam, '50');
    expect(texts, contains("That's ₹10 more than the balance."));
    expect(texts.where((s) => s.contains('will owe')), isEmpty);
    final table = tester.widget<BeforeAfterTable>(
      find.byType(BeforeAfterTable),
    );
    final rows = {for (final e in table.entries) e.title: e.after.minor};
    expect(rows['You and Sam'], 0);
    expect(rows['You and Priya'], 1000);
    await tester.runAsync(p.dispose);
  });

  testWidgets('MONEY-R24-01: when someone pays me more than they owe, the '
      'screen says I will owe them the extra, not that they will owe me', (
    tester,
  ) async {
    late QaPhone p;
    late GroupId g;
    late MemberId me, sam;
    await tester.runAsync(() async {
      p = await QaPhone.create();
      final t = await p.group(['Sam'], simplify: true);
      g = t.g;
      me = t.m['me']!;
      sam = t.m['Sam']!;
      await p.add(
        g,
        total: 6000,
        paidBy: one(me, 6000),
        owedBy: one(sam, 6000),
      );
    });
    final texts = await settleTexts(tester, p, g, sam, me, '70');
    expect(
      texts,
      contains("That's ₹10 more than the balance. You will owe Sam ₹10."),
    );
    await tester.runAsync(p.dispose);
  });

  testWidgets('MONEY-R24-01: a payment between two others that is more '
      'than the balance says who will owe whom', (tester) async {
    late QaPhone p;
    late GroupId g;
    late MemberId sam, priya;
    await tester.runAsync(() async {
      p = await QaPhone.create();
      final t = await p.group(['Sam', 'Priya'], simplify: true);
      g = t.g;
      sam = t.m['Sam']!;
      priya = t.m['Priya']!;
      await p.add(
        g,
        total: 6000,
        paidBy: one(priya, 6000),
        owedBy: one(sam, 6000),
      );
    });
    final texts = await settleTexts(tester, p, g, sam, priya, '70');
    expect(
      texts,
      contains("That's ₹10 more than the balance. Priya will owe Sam ₹10."),
    );
    final table = tester.widget<BeforeAfterTable>(
      find.byType(BeforeAfterTable),
    );
    expect(table.entries.single.after.word, 'Priya owes');
    expect(table.entries.single.after.minor, 1000);
    await tester.runAsync(p.dispose);
  });
}
