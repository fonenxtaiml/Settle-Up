// QA MONEY round 44: final full regression sweep of money correctness.
//
// Three phones share one group and run seeded random money commands offline
// (add with every split method and several payers, money edits of amount,
// currency, payer and split, delete, restore, edit while deleted, payments,
// updatePayment with a flipped direction or a new currency, merges,
// removals, simplify toggles), syncing random pairs in between. After a full
// ring sync all three must hold the same expenses, nets, transfers and CSV,
// and every money invariant must hold on each (nets sum to zero per
// currency, shares sum to the total, both views settle the nets exactly,
// simplify gives at most n-1 transfers, overall == sum of my group nets for
// a phone that claimed a member and is empty for one that did not). The CSV
// is read back: every row's member cells sum to zero and the column sums
// equal the nets of the members they stand for.
//
// Then the charter's fixed vectors once more through Ledger.addExpense,
// formula-leading text in every CSV text cell, and the amount grammar.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/csv_export.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/core/split.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/format/amount_input.dart';

import 'money_harness.dart';

const _codes = ['INR', 'JPY', 'KWD'];

/// RFC 4180 reader (records end with CRLF; quoted cells may hold "" CR LF).
List<List<String>> _csv(String s) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  var atStart = true;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
      continue;
    }
    if (ch == '"' && atStart) {
      quoted = true;
      atStart = false;
    } else if (ch == ',') {
      row.add(cell.toString());
      cell.clear();
      atStart = true;
    } else if (ch == '\r') {
      expect(s[i + 1], '\n', reason: 'CRLF');
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
      atStart = true;
      i++;
    } else {
      expect(ch, isNot('\n'), reason: 'bare LF outside quotes');
      expect(ch, isNot('"'), reason: 'quote in an unquoted cell');
      cell.write(ch);
      atStart = false;
    }
  }
  expect(row, isEmpty, reason: 'last record ends with CRLF');
  return rows;
}

int _minor(String text, String code) {
  final c = Currencies.of(code);
  final m = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(text);
  expect(m, isNotNull, reason: 'CSV amount "$text"');
  final frac = m!.group(3) ?? '';
  expect(frac.length, c.minorDigits, reason: 'digits of "$text" ($code)');
  final v =
      int.parse(m.group(2)!) * c.minorPerMajor +
      (frac.isEmpty ? 0 : int.parse(frac));
  return m.group(1) == '-' ? -v : v;
}

/// The CSV agrees with the group's nets: rows sum to zero, column sums per
/// currency are the nets of the (resolved) member each column names.
void _expectCsvMatchesNets(GroupState g, String why) {
  final rows = _csv(CsvExport.group(g));
  final head = rows.first;
  expect(head.sublist(0, 5), [
    'Date',
    'Description',
    'Category',
    'Cost',
    'Currency',
  ]);
  final cols = head.sublist(5);
  expect(cols.toSet().length, cols.length, reason: 'unique columns$why');
  expect(rows.length - 1, g.liveExpenses.length, reason: 'rows$why');
  final sums = <String, Map<String, int>>{};
  for (final row in rows.skip(1)) {
    expect(row.length, head.length, reason: 'row width$why');
    var rowSum = 0;
    final cur = sums.putIfAbsent(row[4], () => {});
    for (var i = 0; i < cols.length; i++) {
      final v = _minor(row[5 + i], row[4]);
      rowSum += v;
      cur[cols[i]] = (cur[cols[i]] ?? 0) + v;
    }
    expect(rowSum, 0, reason: 'row sums to zero$why: $row');
  }
  sums.forEach((_, m) => m.removeWhere((_, v) => v == 0));
  sums.removeWhere((_, m) => m.isEmpty);
  final want = <String, Map<String, int>>{};
  BalanceCalculator.groupNets(g).forEach((c, byMember) {
    want[c] = {
      for (final e in byMember.entries)
        _cellText(g.members[e.key]!.displayName): e.value,
    };
  });
  expect(sums, want, reason: 'CSV column sums == nets$why');
}

/// How a text cell reads back: formula-leading text carries a `'`.
String _cellText(String s) =>
    s.isNotEmpty && '=+-@\t\r'.contains(s[0]) ? "'$s" : s;

Future<void> _threePhoneFuzz(int seed) async {
  final r = Random(seed);
  final a = await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa');
  final b = await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb');
  final c = await QaPhone.create(name: 'Zed', prefix: 'cccccccc');
  final phones = [a, b, c];
  addTearDown(() async {
    for (final x in phones) {
      await x.dispose();
    }
  });
  final t = await a.group([
    'Sam',
    'Priya',
    'Dev',
    'Eve',
  ], simplify: r.nextBool());
  final g = t.g;
  await shareGroup(a, b, g);
  await shareGroup(a, c, g);
  await syncBoth(a, b, g);
  await syncBoth(a, c, g);
  // Sam's phone claims Sam; Zed's phone is in no member (me not a member).
  await b.ledger.claimMember(g, t.m['Sam']!);
  await pumpEventQueue();
  await syncBoth(a, b, g);
  await syncBoth(b, c, g);
  final members = t.m.values.toList()..sort();

  int below(int n) => n <= 1 << 32
      ? r.nextInt(n)
      : (r.nextDouble() * n).floor().clamp(0, n - 1);
  List<MemberId> who(int max) =>
      (List.of(members)..shuffle(r)).take(1 + r.nextInt(max)).toList();
  int total(String code) => switch (r.nextInt(5)) {
    0 => 1 + r.nextInt(3),
    1 => Money.maxMinor - r.nextInt(3),
    _ => 1 + r.nextInt(code == 'JPY' ? 50000 : 5000000),
  };

  SplitSpec owedSpec(int tot) {
    final ms = who(5);
    switch (r.nextInt(5)) {
      case 0:
        return SplitSpec.equal(ms);
      case 1:
        final w = SplitCalculator.allocate(tot, {
          for (final m in ms) m: 1 + r.nextInt(4),
        });
        return SplitSpec(SplitMethod.exact, {for (final m in ms) m: w[m] ?? 0});
      case 2:
        final v = <MemberId, int>{};
        var left = 10000;
        for (var i = 0; i < ms.length; i++) {
          final x = i == ms.length - 1 ? left : r.nextInt(left + 1);
          v[ms[i]] = x;
          left -= x;
        }
        return SplitSpec(SplitMethod.percent, v);
      case 3:
        return SplitSpec(SplitMethod.shares, {
          for (final m in ms) m: r.nextBool() ? 1000 : 1 + r.nextInt(3),
        });
      default:
        final adj = <MemberId, int>{};
        final cap = tot ~/ (ms.length + 1);
        for (final m in ms) {
          adj[m] = cap == 0 ? 0 : below(cap + 1) - below(cap ~/ 2 + 1);
        }
        return SplitSpec(SplitMethod.adjustment, adj);
    }
  }

  SplitSpec paidSpec(int tot) {
    final ps = who(3);
    switch (r.nextInt(4)) {
      case 0:
        return SplitSpec.single(ps.first, tot);
      case 1:
        return SplitSpec.equal(ps);
      case 2:
        final v = <MemberId, int>{};
        var left = 10000;
        for (var i = 0; i < ps.length; i++) {
          final x = i == ps.length - 1 ? left : 1 + r.nextInt(max(1, left));
          v[ps[i]] = min(x, left);
          left -= v[ps[i]]!;
        }
        return SplitSpec(SplitMethod.percent, v);
      default:
        return SplitSpec(SplitMethod.shares, {
          for (final m in ps) m: 1 + r.nextInt(5),
        });
    }
  }

  var done = 0;
  Future<void> step(QaPhone x) async {
    x.tick(1 + r.nextInt(5000));
    final gs = x.gs(g);
    final all = gs.expenses.values.toList()
      ..sort((p, q) => p.id.compareTo(q.id));
    final exps = all.where((e) => !e.isPayment).toList();
    final pays = all.where((e) => e.isPayment).toList();
    try {
      switch (r.nextInt(11)) {
        case 0 || 1 || 2:
          final code = _codes[r.nextInt(_codes.length)];
          final tot = total(code);
          await x.add(
            g,
            total: tot,
            currency: code,
            paidBy: paidSpec(tot),
            owedBy: owedSpec(tot),
          );
        case 3 || 4:
          if (exps.isEmpty) return;
          final e = exps[r.nextInt(exps.length)];
          final code = r.nextInt(3) == 0
              ? _codes[r.nextInt(_codes.length)]
              : e.money.currency;
          final tot = r.nextBool() ? e.money.total : total(code);
          await x.ledger.updateExpense(
            e.id,
            ExpenseDraft(
              groupId: g,
              description: r.nextBool()
                  ? e.description
                  : 'Edit ${r.nextInt(99)}',
              total: tot,
              currency: code,
              paidBy: r.nextBool() && tot == e.money.total
                  ? e.money.paidBy
                  : paidSpec(tot),
              owedBy: owedSpec(tot),
              category: e.category,
              date: e.date,
            ),
          );
        case 5:
          if (all.isEmpty) return;
          final e = all[r.nextInt(all.length)];
          await x.ledger.deleteExpense(e.id, groupId: g);
        case 6:
          if (all.isEmpty) return;
          final e = all[r.nextInt(all.length)];
          await x.ledger.restoreExpense(e.id, groupId: g);
        case 7:
          final ms = who(5);
          if (ms.length < 2) return;
          final code = _codes[r.nextInt(_codes.length)];
          await x.pay(
            g,
            from: ms[0],
            to: ms[1],
            amount: total(code),
            currency: code,
          );
        case 8:
          if (pays.isEmpty) return;
          final e = pays[r.nextInt(pays.length)];
          final flip = r.nextBool();
          await x.ledger.updatePayment(
            e.id,
            PaymentDraft(
              groupId: g,
              from: flip ? e.receiver : e.payer,
              to: flip ? e.payer : e.receiver,
              amount: r.nextBool() ? e.money.total : total(e.money.currency),
              currency: r.nextInt(3) == 0
                  ? _codes[r.nextInt(_codes.length)]
                  : e.money.currency,
              method: PaymentMethod.cash,
              date: e.date,
            ),
          );
        case 9:
          final ms = who(5);
          if (ms.length < 2 || r.nextInt(3) != 0) return;
          if (r.nextBool()) {
            await x.ledger.mergeMembers(g, from: ms[0], into: ms[1]);
          } else if (ms[0] != t.m['me'] && ms[0] != t.m['Sam']) {
            await x.ledger.removeMember(g, ms[0]);
          }
        default:
          await x.ledger.updateGroup(
            g,
            GroupPatch(simplifyDebts: !gs.group!.simplifyDebts),
          );
      }
      done++;
    } on LedgerException {
      // A refused command (merge into a removed member, a percent payer
      // split that is off): nothing was written.
    }
    await pumpEventQueue();
  }

  for (var round = 0; round < 30; round++) {
    for (var k = 0; k < 4; k++) {
      await step(phones[r.nextInt(3)]);
    }
    final i = r.nextInt(3);
    final j = (i + 1 + r.nextInt(2)) % 3;
    await syncBoth(phones[i], phones[j], g);
    for (final x in phones) {
      expectMoneyInvariants(x, reason: 'seed $seed round $round');
    }
  }
  for (var k = 0; k < 2; k++) {
    await syncBoth(a, b, g);
    await syncBoth(b, c, g);
    await syncBoth(c, a, g);
  }

  expect(done, greaterThan(40), reason: 'commands that ran (seed $seed)');
  expect(a.gs(g).liveExpenses, isNotEmpty);
  final ref = a.gs(g);
  for (final x in phones) {
    final gs = x.gs(g);
    final why = ' (seed $seed, ${x.settings.profile!.displayName})';
    expect(
      {for (final e in gs.expenses.values) e.id: e.money.toJson()},
      {for (final e in ref.expenses.values) e.id: e.money.toJson()},
      reason: 'same money blocks$why',
    );
    expect(
      {for (final e in gs.expenses.values) e.id: e.isDeleted},
      {for (final e in ref.expenses.values) e.id: e.isDeleted},
      reason: 'same deleted flags$why',
    );
    expect(x.nets(g), BalanceCalculator.groupNets(ref), reason: 'nets$why');
    expect(x.transfers(g), a.transfers(g), reason: 'transfers$why');
    expect(CsvExport.group(gs), CsvExport.group(ref), reason: 'CSV$why');
    expectMoneyInvariants(x, reason: 'converged$why');
    _expectCsvMatchesNets(gs, why);
    // Both views move the same money per person.
    final nets = BalanceCalculator.groupNets(gs);
    for (final cur in nets.keys) {
      final simplified = DebtSimplifier.simplify(nets[cur]!, cur);
      final original = BalanceCalculator.cancelCycles(
        BalanceCalculator.pairwiseDebts(gs),
      ).where((t) => t.currency == cur);
      Map<MemberId, int> per(Iterable<Transfer> ts) {
        final m = <MemberId, int>{};
        for (final t in ts) {
          m[t.from] = (m[t.from] ?? 0) - t.amount;
          m[t.to] = (m[t.to] ?? 0) + t.amount;
        }
        m.removeWhere((_, v) => v == 0);
        return m;
      }

      expect(per(simplified), per(original), reason: 'per-person$why $cur');
    }
  }
  // My net on Sam's phone is Sam's resolved member's net; Zed's is empty.
  final gs = b.gs(g);
  final sam = gs.resolve(gs.memberForPerson(b.me)!.id);
  final samNet = <String, int>{
    for (final e in BalanceCalculator.groupNets(gs).entries)
      if ((e.value[sam] ?? 0) != 0) e.key: e.value[sam]!,
  };
  expect(b.overall().net, samNet, reason: 'Sam overall (seed $seed)');
  expect(c.overall().net, isEmpty, reason: 'not a member (seed $seed)');
  expect(c.people(), isEmpty, reason: 'not a member (seed $seed)');
}

void main() {
  group('R44 three phones, random money commands, ring sync', () {
    for (var seed = 1; seed <= 30; seed++) {
      test('seed $seed', () => _threePhoneFuzz(seed));
    }
  });

  group('R44 charter vectors through Ledger.addExpense', () {
    test('splits, ties, currencies, extremes', () async {
      final p = await QaPhone.create();
      addTearDown(p.dispose);
      final t = await p.group(['Cy', 'Bo']);
      final g = t.g;
      // al < bo < cy by id; specs list them in other orders.
      final ids = t.m.values.toList()..sort();
      final al = ids[0], bo = ids[1], cy = ids[2];

      Future<Map<MemberId, int>> owed(
        int total,
        SplitSpec s, {
        String code = 'INR',
      }) async => p.owed(
        await p.add(
          g,
          total: total,
          currency: code,
          paidBy: one(cy, total),
          owedBy: s,
        ),
      );

      expect(await owed(1000, eq([cy, bo, al])), {al: 334, bo: 333, cy: 333});
      expect(await owed(100, eq([cy, al, bo])), {al: 34, bo: 33, cy: 33});
      expect(await owed(1, eq([cy, bo, al])), {al: 1});
      expect(await owed(2, eq([cy, bo, al])), {al: 1, bo: 1});
      expect(
        await owed(
          1000,
          spec(SplitMethod.percent, {al: 3333, bo: 3333, cy: 3334}),
        ),
        {al: 333, bo: 333, cy: 334},
      );
      expect(
        await owed(1000, spec(SplitMethod.percent, {al: 0, bo: 10000, cy: 0})),
        {bo: 1000},
        reason: 'zero-weight participants dropped',
      );
      expect(await owed(1000, spec(SplitMethod.shares, {al: 2, bo: 1})), {
        al: 667,
        bo: 333,
      });
      expect(await owed(1001, spec(SplitMethod.shares, {al: 1000, bo: 1})), {
        al: 1000,
        bo: 1,
      });
      expect(
        await owed(
          6000,
          spec(SplitMethod.adjustment, {al: 1000, bo: 0, cy: 0}),
        ),
        {al: 2667, bo: 1667, cy: 1666},
      );
      expect(
        await owed(
          6000,
          spec(SplitMethod.adjustment, {al: 1000, bo: 2000, cy: 3000}),
        ),
        {al: 1000, bo: 2000, cy: 3000},
        reason: 'adjustments leave a rest of exactly 0',
      );
      expect(
        await owed(
          6000,
          spec(SplitMethod.adjustment, {al: -1000, bo: 0, cy: 0}),
        ),
        {al: 1334, bo: 2333, cy: 2333},
        reason: 'valid negative adjustment',
      );
      await expectLater(
        owed(6000, spec(SplitMethod.adjustment, {al: -7000, bo: 0})),
        throwsA(isA<LedgerException>()),
      );
      expect(await owed(500, eq([cy, bo, al]), code: 'JPY'), {
        al: 167,
        bo: 167,
        cy: 166,
      });
      expect(await owed(10, eq([bo, al, cy]), code: 'KWD'), {
        al: 4,
        bo: 3,
        cy: 3,
      });
      expect(await owed(Money.maxMinor, eq([cy, bo, al])), {
        al: 33333333333,
        bo: 33333333333,
        cy: 33333333333,
      });
      await expectLater(
        owed(Money.maxMinor + 1, eq([al])),
        throwsA(isA<LedgerException>()),
      );
      for (final e in p.gs(g).liveExpenses) {
        expect(e.money.owed.values.fold(0, (x, y) => x + y), e.money.total);
      }
      expectMoneyInvariants(p, reason: 'charter vectors');
    });

    test('maxMinor over 50 members and 1 minor unit over 50', () async {
      final p = await QaPhone.create();
      addTearDown(p.dispose);
      final t = await p.group([for (var i = 1; i < 50; i++) 'P$i']);
      final ms = t.m.values.toList()..sort();
      final big = await p.add(
        t.g,
        total: Money.maxMinor,
        paidBy: eq(ms.take(7)),
        owedBy: eq(ms),
      );
      final owed = p.owed(big);
      expect(owed.values.fold(0, (a, b) => a + b), Money.maxMinor);
      final q = Money.maxMinor ~/ 50, extra = Money.maxMinor % 50;
      for (final (i, m) in ms.indexed) {
        expect(owed[m], q + (i < extra ? 1 : 0), reason: 'member $i');
      }
      final tiny = await p.add(
        t.g,
        total: 1,
        paidBy: one(ms.last, 1),
        owedBy: eq(ms.reversed),
      );
      expect(p.owed(tiny), {ms.first: 1});
      expectMoneyInvariants(p, reason: '50 members');
      expect(p.transfers(t.g).length, lessThanOrEqualTo(49));
    });

    test('SPEC 6.3 pairwise vector and settle up exact, partial, over, '
        'by creditor, second currency', () async {
      final p = await QaPhone.create();
      addTearDown(p.dispose);
      final t = await p.group(['Bo', 'Cy'], simplify: false);
      final g = t.g;
      final ids = t.m.values.toList()..sort();
      final a = ids[0], b = ids[1], c = ids[2];
      await p.add(g, total: 9000, paidBy: one(a, 9000), owedBy: eq([a, b, c]));
      await p.add(
        g,
        total: 3000,
        paidBy: one(b, 3000),
        owedBy: spec(SplitMethod.exact, {a: 1500, b: 1500}),
      );
      expect(BalanceCalculator.pairwiseDebts(p.gs(g)), [
        Transfer(from: b, to: a, amount: 1500, currency: 'INR'),
        Transfer(from: c, to: a, amount: 3000, currency: 'INR'),
      ]);
      await p.add(
        g,
        total: 900,
        currency: 'JPY',
        paidBy: one(c, 900),
        owedBy: eq([a, c]),
      );
      // Partial by the debtor, then over-payment flips the direction.
      await p.pay(g, from: b, to: a, amount: 1000);
      expect(p.nets(g)['INR']![b], -500);
      await p.pay(g, from: b, to: a, amount: 800);
      expect(p.nets(g)['INR']![b], 300);
      expect(
        p.transfers(g).where((x) => x.currency == 'INR' && x.to == b).single,
        Transfer(from: a, to: b, amount: 300, currency: 'INR'),
      );
      // Recorded by the creditor (this phone is Alex, the payee): same.
      await p.pay(g, from: c, to: a, amount: 3000);
      // A JPY payment settles only JPY.
      await p.pay(g, from: a, to: c, amount: 450, currency: 'JPY');
      expect(p.nets(g), {
        'INR': {a: -300, b: 300},
      });
      final mine = t.m['me']!;
      expect(p.overall().net, {
        if (mine == a) 'INR': -300,
        if (mine == b) 'INR': 300,
      });
      expectMoneyInvariants(p, reason: 'settle up');
    });
  });

  test('R44 CSV: formula-leading text in names, descriptions and payment '
      'labels is defused, quotes and line breaks are escaped', () async {
    final p = await QaPhone.create(name: '=Alex');
    addTearDown(p.dispose);
    final t = await p.group(['+Sam', '-Priya', '@Dev', 'Eve, "the" one']);
    final g = t.g;
    final me = t.m['me']!, sam = t.m['+Sam']!;
    final dev = t.m['@Dev']!, eve = t.m['Eve, "the" one']!;
    await p.add(
      g,
      total: 1000,
      description: '=HYPERLINK("x")',
      paidBy: one(me, 1000),
      owedBy: eq([me, sam, dev, eve]),
    );
    await p.add(
      g,
      total: 300,
      currency: 'KWD',
      description: 'line1\nline2',
      paidBy: one(eve, 300),
      owedBy: eq([me, eve]),
    );
    await p.pay(g, from: sam, to: me, amount: 250);
    final rows = _csv(CsvExport.group(p.gs(g)));
    for (final row in rows) {
      for (final (i, cell) in row.indexed) {
        if (row != rows.first && i >= 3 && i != 4) continue; // numbers
        expect(
          cell.isEmpty || !'=+-@\t\r'.contains(cell[0]),
          isTrue,
          reason: 'cell "$cell" would run as a formula',
        );
      }
    }
    expect(rows.first, contains("'=Alex"));
    expect(rows.first, contains('Eve, "the" one'));
    expect(rows.skip(1).map((r) => r[1]), contains("'=HYPERLINK(\"x\")"));
    expect(rows.skip(1).map((r) => r[1]), contains('line1\nline2'));
    expect(rows.skip(1).map((r) => r[1]), contains("'+Sam paid =Alex"));
    _expectCsvMatchesNets(p.gs(g), ' (formula names)');
  });

  test('R44 amount grammar: grouping, decimal comma, KWD, too many '
      'decimals', () {
    final inr = Currencies.of('INR');
    final eur = Currencies.of('EUR');
    final kwd = Currencies.of('KWD');
    final jpy = Currencies.of('JPY');
    expect(parseAmountInput('1,234.50', inr), 123450);
    expect(parseAmountInput('12,34,567', inr), 123456700);
    expect(parseAmountInput('1.234,50', eur), 123450);
    expect(parseAmountInput('12.345', kwd), 12345);
    expect(parseAmountInput('1,250', kwd), 1250000);
    expect(readAmount('12.345', inr).issue, AmountIssue.decimals);
    expect(readAmount('800.5', jpy).issue, AmountIssue.decimals);
    expect(parseAmountInput('50.000', jpy), 50000);
    expect(parseAmountInput('-30', inr), isNull);
    expect(parseSignedAmountInput('−30', inr), -3000);
    expect(parseAmountInput('999999999.99', inr), Money.maxMinor);
    expect(readAmount('1000000000.00', inr).issue, AmountIssue.tooLarge);
  });
}
