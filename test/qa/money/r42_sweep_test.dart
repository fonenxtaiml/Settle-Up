// QA MONEY round 42: final regression sweep of money correctness.
//
// The earlier sweeps check the providers against core (the same code). This
// one checks the real Ledger(MemoryOpStore) and Riverpod providers against an
// independent reference written from SPEC 6.1, 6.2, 6.5 and 6.7 alone:
// its own largest-remainder split (BigInt), its own record of every
// expense and payment as last written, its own merge resolution, and a CSV
// parser that reads the exported bytes back. Seeded random commands (add,
// money edits, delete, restore, payments, updatePayment, merges, removals,
// simplify toggles) over INR, JPY, KWD and USD, every split method, several
// payers, totals from 1 to Money.maxMinor, with every result compared after
// every command, plus two phones whose concurrent merges form a cycle.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/format/amount_input.dart';
import 'package:settle_up/ui/format/face_value.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/screens/csv_share.dart';

import 'money_harness.dart';

const _currencies = ['INR', 'JPY', 'KWD', 'USD'];

// ------------------------------------------------------------ reference --

/// SPEC 6.1 allocate, in BigInt, written from the spec text.
Map<String, int> _refAllocate(int total, Map<String, int> weights) {
  final ids = weights.keys.toList()..sort();
  final w = weights.values.fold(BigInt.zero, (a, b) => a + BigInt.from(b));
  if (w == BigInt.zero) throw const _Refused('zeroWeight');
  final t = BigInt.from(total);
  final base = <String, BigInt>{};
  final rem = <String, BigInt>{};
  var assigned = BigInt.zero;
  for (final id in ids) {
    final p = t * BigInt.from(weights[id]!);
    base[id] = p ~/ w;
    rem[id] = p % w;
    assigned += base[id]!;
  }
  var leftover = (t - assigned).toInt();
  final order = [...ids]
    ..sort((a, b) {
      final c = rem[b]!.compareTo(rem[a]!);
      return c != 0 ? c : a.compareTo(b);
    });
  for (final id in order) {
    if (leftover == 0) break;
    base[id] = base[id]! + BigInt.one;
    leftover--;
  }
  return {
    for (final id in ids)
      if (base[id]! != BigInt.zero) id: base[id]!.toInt(),
  };
}

final class _Refused implements Exception {
  const _Refused(this.why);
  final String why;
  @override
  String toString() => 'refused: $why';
}

/// SPEC 6.1 table, from the spec text.
Map<String, int> _refCompute(int total, SplitSpec spec) {
  if (total <= 0 || total > Money.maxMinor) throw const _Refused('total');
  final v = spec.values;
  if (v.isEmpty) throw const _Refused('empty');
  BigInt sum() => v.values.fold(BigInt.zero, (a, b) => a + BigInt.from(b));
  switch (spec.method) {
    case SplitMethod.equal:
      return _refAllocate(total, {for (final m in v.keys) m: 1});
    case SplitMethod.exact:
      if (v.values.any((x) => x < 0)) throw const _Refused('negative');
      if (sum() != BigInt.from(total)) throw const _Refused('sum');
      return {
        for (final m in v.keys.toList()..sort())
          if (v[m] != 0) m: v[m]!,
      };
    case SplitMethod.percent:
      if (v.values.any((x) => x < 0)) throw const _Refused('negative');
      if (sum() != BigInt.from(10000)) throw const _Refused('percent');
      return _refAllocate(total, v);
    case SplitMethod.shares:
      if (v.values.any((x) => x < 1)) throw const _Refused('weight');
      return _refAllocate(total, v);
    case SplitMethod.adjustment:
      final rest = BigInt.from(total) - sum();
      if (rest < BigInt.zero) throw const _Refused('adjustment');
      final base = rest == BigInt.zero
          ? <String, int>{}
          : _refAllocate(rest.toInt(), {for (final m in v.keys) m: 1});
      final out = <String, int>{};
      for (final m in v.keys.toList()..sort()) {
        final s = (base[m] ?? 0) + v[m]!;
        if (s < 0) throw const _Refused('negative share');
        if (s != 0) out[m] = s;
      }
      return out;
  }
}

final class _Rec {
  _Rec(this.total, this.currency, this.paid, this.owed);
  int total;
  String currency;
  Map<String, int> paid;
  Map<String, int> owed;
  bool deleted = false;
}

/// SPEC 6.7 resolve, from the spec text.
String _refResolve(Map<String, String?> mergedInto, String id) {
  final seen = <String>[];
  var cur = id;
  while (true) {
    // Every member exists in these tests: an unmerged one is the end.
    if (!mergedInto.containsKey(cur)) return cur;
    final i = seen.indexOf(cur);
    if (i >= 0) {
      final cycle = seen.sublist(i)..sort();
      return cycle.first;
    }
    seen.add(cur);
    final next = mergedInto[cur];
    if (next == null) return cur;
    cur = next;
  }
}

Map<String, Map<String, int>> _refNets(
  Map<String, _Rec> recs,
  Map<String, String?> mergedInto,
) {
  final nets = <String, Map<String, int>>{};
  for (final r in recs.values) {
    if (r.deleted) continue;
    final cur = nets.putIfAbsent(r.currency, () => {});
    r.paid.forEach((m, v) {
      final k = _refResolve(mergedInto, m);
      cur[k] = (cur[k] ?? 0) + v;
    });
    r.owed.forEach((m, v) {
      final k = _refResolve(mergedInto, m);
      cur[k] = (cur[k] ?? 0) - v;
    });
  }
  for (final c in nets.values) {
    c.removeWhere((_, v) => v == 0);
  }
  nets.removeWhere((_, c) => c.isEmpty);
  return nets;
}

// ------------------------------------------------------------------ CSV --

/// RFC 4180 reader: records end with CRLF; quoted cells may hold "" , CR LF.
List<List<String>> _parseCsv(String s) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var i = 0;
  var quoted = false;
  var atStart = true;
  while (i < s.length) {
    final ch = s[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          cell.write('"');
          i += 2;
          continue;
        }
        quoted = false;
        i++;
        continue;
      }
      cell.write(ch);
      i++;
      continue;
    }
    if (ch == '"' && atStart) {
      quoted = true;
      atStart = false;
      i++;
      continue;
    }
    if (ch == ',') {
      row.add(cell.toString());
      cell.clear();
      atStart = true;
      i++;
      continue;
    }
    if (ch == '\r') {
      expect(s[i + 1], '\n', reason: 'record ends with CRLF');
      row.add(cell.toString());
      cell.clear();
      rows.add(row);
      row = <String>[];
      atStart = true;
      i += 2;
      continue;
    }
    expect(ch, isNot('\n'), reason: 'bare LF outside quotes');
    expect(ch, isNot('"'), reason: 'quote inside an unquoted cell');
    cell.write(ch);
    atStart = false;
    i++;
  }
  expect(row, isEmpty, reason: 'the last record ends with CRLF');
  expect(cell.toString(), isEmpty);
  return rows;
}

/// A CSV decimal (ASCII '-', '.', the currency's digits) to minor units.
int _csvMinor(String text, String code) {
  final c = Currencies.of(code);
  final m = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(text);
  expect(m, isNotNull, reason: 'CSV amount "$text" ($code)');
  final frac = m!.group(3) ?? '';
  expect(frac.length, c.minorDigits, reason: 'CSV digits of "$text" ($code)');
  final v =
      int.parse(m.group(2)!) * c.minorPerMajor +
      (frac.isEmpty ? 0 : int.parse(frac));
  return m.group(1) == '-' ? -v : v;
}

/// The exported bytes, read back, agree with the reference: one row per live
/// record, member columns summing to zero per row, and per currency every
/// member's column sum equal to the reference net (nobody's balance lost).
void _expectCsv(
  GroupState g,
  Map<String, _Rec> recs,
  Map<String, String?> mergedInto,
  Map<String, String> nameOf,
  String why,
) {
  final bytes = csvBytes(g);
  expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF], reason: 'BOM$why');
  final rows = _parseCsv(utf8.decode(bytes.sublist(3)));
  final head = rows.first;
  expect(head.sublist(0, 5), [
    'Date',
    'Description',
    'Category',
    'Cost',
    'Currency',
  ], reason: 'columns$why');
  final cols = head.sublist(5);
  expect(cols.toSet().length, cols.length, reason: 'unique columns$why');
  final live = recs.values.where((r) => !r.deleted).toList();
  expect(rows.length - 1, live.length, reason: 'one row per live record$why');
  final sums = <String, Map<String, int>>{};
  for (final row in rows.skip(1)) {
    expect(row.length, head.length, reason: 'row width$why');
    final code = row[4];
    final total = _csvMinor(row[3], code);
    expect(total, greaterThan(0));
    var rowSum = 0;
    final cur = sums.putIfAbsent(code, () => {});
    for (var i = 0; i < cols.length; i++) {
      final v = _csvMinor(row[5 + i], code);
      rowSum += v;
      cur[cols[i]] = (cur[cols[i]] ?? 0) + v;
    }
    expect(rowSum, 0, reason: 'row member cells sum to zero$why: $row');
  }
  // Multiset of (currency, total) rows == reference.
  final want = [for (final r in live) '${r.currency} ${r.total}']..sort();
  final got = [
    for (final row in rows.skip(1)) '${row[4]} ${_csvMinor(row[3], row[4])}',
  ]..sort();
  expect(got, want, reason: 'CSV costs$why');
  final ref = _refNets(recs, mergedInto);
  final byName = <String, Map<String, int>>{};
  ref.forEach((c, byMember) {
    byName[c] = {for (final e in byMember.entries) nameOf[e.key]!: e.value};
  });
  sums.forEach((c, byCol) => byCol.removeWhere((_, v) => v == 0));
  sums.removeWhere((_, v) => v.isEmpty);
  expect(sums, byName, reason: 'CSV column sums == reference nets$why');
}

// ----------------------------------------------------------------- fuzz --

Future<void> _oracleFuzz(int seed) async {
  final r = Random(seed);
  final p = await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa');
  addTearDown(p.dispose);
  final t = await p.group([
    'Sam',
    'Priya',
    'Dev',
    'Eve',
    'Noor',
  ], simplify: r.nextBool());
  final g = t.g;
  final members = t.m.values.toList()..sort();
  final nameOf = {
    for (final e in t.m.entries) e.value: e.key == 'me' ? 'Alex' : e.key,
  };
  final myMember = t.m['me']!;
  final recs = <String, _Rec>{};
  final payments = <String>[];
  final expenses = <String>[];
  final mergedInto = <String, String?>{};
  final removed = <String>{};

  int below(int n) => n <= 1 << 32
      ? r.nextInt(n)
      : (r.nextDouble() * n).floor().clamp(0, n - 1);
  int randomTotal() => switch (r.nextInt(6)) {
    0 => 1 + r.nextInt(3),
    1 => Money.maxMinor - r.nextInt(3),
    2 => 1 + below(Money.maxMinor),
    _ => 1 + r.nextInt(100000),
  };
  List<String> who(int max) =>
      (List.of(members)..shuffle(r)).take(1 + r.nextInt(max)).toList();

  SplitSpec randomSpec(int total, {bool payer = false}) {
    final ms = who(payer ? 3 : 6);
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
        return SplitSpec.equal(ms);
      case SplitMethod.exact:
        // Usually valid; sometimes off by one (must be refused).
        final cut = _refAllocate(total, {
          for (final m in ms) m: 1 + r.nextInt(5),
        });
        final v = {for (final m in ms) m: cut[m] ?? 0};
        if (r.nextInt(8) == 0) v[ms.first] = v[ms.first]! + 1;
        return SplitSpec(SplitMethod.exact, v);
      case SplitMethod.percent:
        final v = <String, int>{};
        var left = 10000;
        for (var i = 0; i < ms.length; i++) {
          final x = i == ms.length - 1 ? left : r.nextInt(left + 1);
          v[ms[i]] = x;
          left -= x;
        }
        if (r.nextInt(10) == 0) v[ms.first] = v[ms.first]! + 1;
        return SplitSpec(SplitMethod.percent, v);
      case SplitMethod.shares:
        return SplitSpec(SplitMethod.shares, {
          for (final m in ms)
            m: r.nextInt(6) == 0
                ? 1000
                : (r.nextInt(12) == 0 ? 0 : 1 + r.nextInt(4)),
        });
      case SplitMethod.adjustment:
        final v = <String, int>{};
        for (final m in ms) {
          v[m] = switch (r.nextInt(4)) {
            0 => 0,
            1 => -below(total ~/ ms.length + 2),
            _ => below(total ~/ (ms.length + 1) + 1),
          };
        }
        return SplitSpec(SplitMethod.adjustment, v);
    }
  }

  void check(String why) {
    final gs = p.gs(g);
    final ref = _refNets(recs, mergedInto);
    expect(p.nets(g), ref, reason: 'groupNets == reference$why');
    for (final e in recs.entries) {
      final ex = gs.expenses[e.key];
      expect(ex, isNotNull, reason: 'record ${e.key} visible$why');
      expect(ex!.isDeleted, e.value.deleted, reason: 'deleted flag$why');
      expect(ex.money.total, e.value.total, reason: 'total$why');
      expect(ex.money.currency, e.value.currency, reason: 'currency$why');
      expect(ex.money.paid, e.value.paid, reason: 'paid shares$why');
      expect(ex.money.owed, e.value.owed, reason: 'owed shares$why');
    }
    for (final m in members) {
      expect(
        gs.resolve(m),
        _refResolve(mergedInto, m),
        reason: 'resolve $m$why',
      );
    }
    // My net, overall (both toggles give the same overall).
    final mine = _refResolve(mergedInto, myMember);
    final myRef = <String, int>{
      for (final c in ref.keys)
        if ((ref[c]![mine] ?? 0) != 0) c: ref[c]![mine]!,
    };
    expect(p.overall().net, myRef, reason: 'overall.net == reference$why');
    expect(
      Summaries.myNetInGroup(gs, p.me),
      myRef,
      reason: 'myNetInGroup == reference$why',
    );
    // Both views settle the same nets; simplify gives <= n-1 per currency.
    for (final view in [
      BalanceCalculator.pairwiseDebts(gs),
      BalanceCalculator.cancelCycles(BalanceCalculator.pairwiseDebts(gs)),
      p.transfers(g),
    ]) {
      final left = {for (final c in ref.keys) c: Map<String, int>.of(ref[c]!)};
      for (final x in view) {
        final cur = left.putIfAbsent(x.currency, () => {});
        cur[x.from] = (cur[x.from] ?? 0) + x.amount;
        cur[x.to] = (cur[x.to] ?? 0) - x.amount;
        expect(x.amount, greaterThan(0));
        expect(x.from, isNot(x.to));
        expect(gs.resolve(x.from), x.from, reason: 'resolved from$why');
        expect(gs.resolve(x.to), x.to, reason: 'resolved to$why');
      }
      for (final c in left.values) {
        expect(c.values.where((v) => v != 0), isEmpty, reason: 'settles$why');
      }
    }
    for (final c in ref.keys) {
      expect(
        DebtSimplifier.simplify(ref[c]!, c).length,
        lessThanOrEqualTo(ref[c]!.length - 1),
      );
    }
    _expectCsv(gs, recs, mergedInto, nameOf, why);
    expectMoneyInvariants(p, reason: why);
  }

  var accepted = 0;
  final kinds = <String, int>{};
  for (var step = 0; step < 90; step++) {
    p.tick();
    final total = randomTotal();
    final cur = _currencies[r.nextInt(_currencies.length)];
    String what = '';
    // What the reference expects of a draft (null = refused).
    _Rec? refDraft(int total, String cur, SplitSpec paid, SplitSpec owed) {
      try {
        return _Rec(
          total,
          cur,
          _refCompute(total, paid),
          _refCompute(total, owed),
        );
      } on _Refused {
        return null;
      }
    }

    final paid = randomSpec(total, payer: true);
    final owed = randomSpec(total);
    final want = refDraft(total, cur, paid, owed);
    ExpenseDraft draft() => ExpenseDraft(
      groupId: g,
      description: '=E$step, "x"\r\n-1',
      total: total,
      currency: cur,
      paidBy: paid,
      owedBy: owed,
      category: 'general',
      date: utcFromMillis(kBaseMs + r.nextInt(5) * 86400000),
    );
    var refused = false;
    bool? mergeOk;
    try {
      switch (r.nextInt(11)) {
        case 0 || 1 || 2:
          what = 'add';
          final id = await p.ledger.addExpense(draft());
          expect(want, isNotNull, reason: 'added a draft the spec refuses');
          recs[id] = want!;
          expenses.add(id);
        case 3 when expenses.isNotEmpty:
          what = 'edit';
          final id = expenses[r.nextInt(expenses.length)];
          await p.ledger.updateExpense(id, draft());
          expect(want, isNotNull, reason: 'edit the spec refuses');
          final d = recs[id]!.deleted;
          recs[id] = want!..deleted = d;
        case 4 when recs.isNotEmpty:
          what = 'delete';
          final id = recs.keys.elementAt(r.nextInt(recs.length));
          await p.ledger.deleteExpense(id, groupId: g);
          recs[id]!.deleted = true;
        case 5 when recs.isNotEmpty:
          what = 'restore';
          final id = recs.keys.elementAt(r.nextInt(recs.length));
          await p.ledger.restoreExpense(id, groupId: g);
          recs[id]!.deleted = false;
        case 6:
          what = 'pay';
          final from = members[r.nextInt(members.length)];
          final to = members[(members.indexOf(from) + 1 + r.nextInt(5)) % 6];
          final id = await p.ledger.recordPayment(
            PaymentDraft(
              groupId: g,
              from: from,
              to: to,
              amount: total,
              currency: cur,
              method: PaymentMethod.cash,
              date: utcFromMillis(kBaseMs),
            ),
          );
          recs[id] = _Rec(total, cur, {from: total}, {to: total});
          payments.add(id);
        case 7 when payments.isNotEmpty:
          what = 'updatePayment';
          final id = payments[r.nextInt(payments.length)];
          // Often the reverse direction (an over-payment flips it).
          final old = recs[id]!;
          final from = r.nextBool()
              ? old.owed.keys.first
              : members[r.nextInt(members.length)];
          final to = from == old.paid.keys.first
              ? old.owed.keys.first
              : old.paid.keys.first;
          if (from == to) break;
          await p.ledger.updatePayment(
            id,
            PaymentDraft(
              groupId: g,
              from: from,
              to: to,
              amount: total,
              currency: cur,
              method: PaymentMethod.bank,
              date: utcFromMillis(kBaseMs),
            ),
          );
          recs[id] = _Rec(total, cur, {from: total}, {to: total})
            ..deleted = old.deleted;
        case 8 when r.nextInt(3) == 0:
          what = 'merge';
          final a = members[r.nextInt(members.length)];
          final b = members[r.nextInt(members.length)];
          final ok =
              a != b &&
              _refResolve(mergedInto, a) != _refResolve(mergedInto, b) &&
              !removed.contains(b);
          mergeOk = ok;
          await p.ledger.mergeMembers(g, from: a, into: b);
          expect(ok, isTrue, reason: 'merge the rules refuse');
          mergedInto[a] = b;
        case 9 when r.nextInt(3) == 0:
          what = 'remove';
          final a = members[r.nextInt(members.length)];
          await p.ledger.removeMember(g, a);
          removed.add(a);
        default:
          what = 'simplify';
          final before = p.overall().net;
          final netsBefore = p.nets(g);
          await p.ledger.updateGroup(
            g,
            GroupPatch(simplifyDebts: !p.gs(g).group!.simplifyDebts),
          );
          await pumpEventQueue();
          expect(p.nets(g), netsBefore, reason: 'toggle keeps nets');
          expect(p.overall().net, before, reason: 'toggle keeps overall');
      }
      accepted++;
      kinds[what] = (kinds[what] ?? 0) + 1;
    } on LedgerException catch (e) {
      refused = true;
      kinds['$what refused'] = (kinds['$what refused'] ?? 0) + 1;
      if (what == 'merge') {
        expect(mergeOk, isFalse, reason: 'refused a valid merge ($e)');
      }
      if (what == 'add' || what == 'edit') {
        expect(
          want,
          isNull,
          reason:
              'seed $seed step $step: ledger refused a draft the spec '
              'accepts ($e) paid $paid owed $owed total $total',
        );
      }
    }
    await pumpEventQueue();
    check(' (seed $seed step $step $what${refused ? ' refused' : ''})');
  }
  expect(accepted, greaterThan(50));
  // Every kind of command ran, and the spec-refused drafts were refused.
  for (final k in ['add', 'edit', 'delete', 'restore', 'pay', 'simplify']) {
    expect(kinds[k], isNotNull, reason: 'seed $seed ran $k: $kinds');
  }
}

void main() {
  group('R42 reference oracle fuzz (ledger + providers + CSV vs SPEC)', () {
    for (final seed in [4201, 4202, 4203, 4204, 4205, 4206, 4207, 4208]) {
      test('seed $seed', () => _oracleFuzz(seed));
    }
  });

  test('R42 concurrent merges A->B and B->A on two phones resolve to the '
      'smaller id; balances, CSV and overall follow', () async {
    final p = await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa');
    final q = await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb');
    addTearDown(() async {
      await p.dispose();
      await q.dispose();
    });
    final t = await p.group(['Bob', 'Bobby', 'Cy']);
    final g = t.g;
    await shareGroup(p, q, g);
    await syncBoth(p, q, g);
    final me = t.m['me']!, bob = t.m['Bob']!, bobby = t.m['Bobby']!;
    final cy = t.m['Cy']!;
    final e1 = await p.add(
      g,
      total: 900,
      paidBy: one(bob, 900),
      owedBy: eq([me, bob, bobby]),
    );
    final e2 = await p.add(
      g,
      total: 601,
      paidBy: one(me, 601),
      owedBy: eq([bobby, cy]),
      currency: 'JPY',
    );
    final pay = await p.pay(
      g,
      from: bobby,
      to: me,
      amount: 100,
      currency: 'JPY',
    );
    await syncBoth(p, q, g);
    p.tick();
    q.tick();
    await p.ledger.mergeMembers(g, from: bob, into: bobby);
    await q.ledger.mergeMembers(g, from: bobby, into: bob);
    await syncBoth(p, q, g);
    final low = ([bob, bobby]..sort()).first;
    for (final x in [p, q]) {
      final gs = x.gs(g);
      expect(gs.resolve(bob), low);
      expect(gs.resolve(bobby), low);
      expectMoneyInvariants(x, reason: 'after merge cycle');
    }
    final recs = {
      e1: _Rec(900, 'INR', {bob: 900}, {me: 300, bob: 300, bobby: 300}),
      e2: _Rec(601, 'JPY', {me: 601}, {bobby: 301, cy: 300}),
      pay: _Rec(100, 'JPY', {bobby: 100}, {me: 100}),
    };
    final merged = <String, String?>{bob: bobby, bobby: bob};
    final ref = _refNets(recs, merged);
    expect(p.nets(g), ref);
    expect(q.nets(g), ref);
    final nameOf = {me: 'Alex', bob: 'Bob', bobby: 'Bobby', cy: 'Cy'};
    _expectCsv(p.gs(g), recs, merged, nameOf, ' (cycle)');
    expect(p.overall().net, {'INR': -300, 'JPY': 501});
    // Paying the merged person settles both former members.
    await p.pay(g, from: me, to: low, amount: 300);
    await p.pay(g, from: low, to: me, amount: 201, currency: 'JPY');
    await p.pay(g, from: cy, to: me, amount: 300, currency: 'JPY');
    expect(p.nets(g), isEmpty);
    expect(p.transfers(g), isEmpty);
    expect(p.overall().net, isEmpty);
    expectMoneyInvariants(p, reason: 'settled after cycle');
  });

  test('R42 payer side refuses what SPEC 6.1 does not list (adjustment '
      'payers) or computes it exactly', () async {
    final p = await QaPhone.create();
    addTearDown(p.dispose);
    final t = await p.group(['Sam', 'Priya']);
    final me = t.m['me']!, sam = t.m['Sam']!;
    ExpenseId? id;
    try {
      id = await p.add(
        t.g,
        total: 1000,
        paidBy: spec(SplitMethod.adjustment, {me: 100, sam: 0}),
        owedBy: eq([me, sam]),
      );
    } on LedgerException {
      // Refused: fine.
    }
    if (id != null) {
      final paid = p.paid(id);
      expect(paid.values.fold(0, (a, b) => a + b), 1000);
      expect(paid, {me: 550, sam: 450});
    }
    expectMoneyInvariants(p);
  });

  group('R42 SPEC vectors through Ledger.addExpense', () {
    test('6.1 table, ties to the lowest id whatever the insertion order, '
        'JPY/KWD, 1 over 3, maxMinor over 50, 6.3 pairwise', () async {
      final p = await QaPhone.create();
      addTearDown(p.dispose);
      final t = await p.group(['Sam', 'Priya']);
      final ids = [t.m['me']!, t.m['Sam']!, t.m['Priya']!]..sort();
      final a = ids[0], b = ids[1], c = ids[2];
      Future<Map<String, int>> owed(
        int total,
        SplitSpec s, [
        String cur = 'INR',
      ]) async => p.owed(
        await p.add(
          t.g,
          total: total,
          paidBy: one(a, total),
          owedBy: s,
          currency: cur,
        ),
      );
      expect(await owed(1000, eq([a, b, c])), {a: 334, b: 333, c: 333});
      expect(await owed(100, eq([c, a, b])), {a: 34, b: 33, c: 33});
      expect(await owed(100, spec(SplitMethod.equal, {c: 1, b: 1, a: 1})), {
        a: 34,
        b: 33,
        c: 33,
      });
      expect(
        await owed(
          1000,
          spec(SplitMethod.percent, {c: 3334, b: 3333, a: 3333}),
        ),
        {a: 333, b: 333, c: 334},
      );
      expect(await owed(1000, spec(SplitMethod.shares, {b: 1, a: 2})), {
        a: 667,
        b: 333,
      });
      expect(await owed(1001, spec(SplitMethod.shares, {c: 1, a: 1000})), {
        a: 1000,
        c: 1,
      });
      expect(
        await owed(6000, spec(SplitMethod.adjustment, {c: 0, b: 0, a: 1000})),
        {a: 2667, b: 1667, c: 1666},
      );
      expect(
        await owed(
          3000,
          spec(SplitMethod.adjustment, {a: 1000, b: 1000, c: 1000}),
        ),
        {a: 1000, b: 1000, c: 1000},
      );
      expect(
        await owed(3000, spec(SplitMethod.adjustment, {a: -500, b: 0, c: 0})),
        {a: 667, b: 1167, c: 1166},
      );
      expect(await owed(1, eq([c, b, a])), {a: 1});
      expect(await owed(500, eq([a, b, c]), 'JPY'), {a: 167, b: 167, c: 166});
      expect(await owed(10, eq([a, b, c]), 'KWD'), {a: 4, b: 3, c: 3});
      expect(
        await owed(1000, spec(SplitMethod.percent, {a: 0, b: 5000, c: 5000})),
        {b: 500, c: 500},
      );
      for (final bad in [
        spec(SplitMethod.exact, {a: 2000, b: 2000, c: 1550}),
        spec(SplitMethod.exact, {a: 2000, b: 2000, c: 2500}),
        spec(SplitMethod.adjustment, {a: -7000, b: 0}),
        spec(SplitMethod.shares, {a: 1, b: 0}),
      ]) {
        await expectLater(
          p.add(t.g, total: 6000, paidBy: one(a, 6000), owedBy: bad),
          throwsA(isA<LedgerException>()),
        );
      }
      expectMoneyInvariants(p);

      // maxMinor over 50 members.
      final big = await p.group([for (var i = 1; i < 50; i++) 'P$i']);
      final all = big.m.values.toList()..sort();
      final e = await p.add(
        big.g,
        total: Money.maxMinor,
        paidBy: one(all.last, Money.maxMinor),
        owedBy: eq(all.reversed),
      );
      final o = p.owed(e);
      expect(o.values.fold(0, (x, y) => x + y), Money.maxMinor);
      // 99,999,999,999 = 50 * 1,999,999,999 + 49: the 49 lowest ids get +1.
      for (var i = 0; i < 50; i++) {
        expect(o[all[i]], i < 49 ? 2000000000 : 1999999999);
      }
      expectMoneyInvariants(p);

      // 6.3 vector, simplify off: [b->a 1500, c->a 3000].
      final q = await QaPhone.create(prefix: 'cccccccc');
      addTearDown(q.dispose);
      final u = await q.group(['Sam', 'Priya'], simplify: false);
      final v = [u.m['me']!, u.m['Sam']!, u.m['Priya']!]..sort();
      await q.add(u.g, total: 9000, paidBy: one(v[0], 9000), owedBy: eq(v));
      await q.add(
        u.g,
        total: 3000,
        paidBy: one(v[1], 3000),
        owedBy: spec(SplitMethod.exact, {v[0]: 1500, v[1]: 1500}),
      );
      expect(q.transfers(u.g), [
        Transfer(from: v[1], to: v[0], amount: 1500, currency: 'INR'),
        Transfer(from: v[2], to: v[0], amount: 3000, currency: 'INR'),
      ]);
      await q.ledger.updateGroup(u.g, const GroupPatch(simplifyDebts: true));
      await pumpEventQueue();
      expect(q.transfers(u.g).length, lessThanOrEqualTo(2));
      expectMoneyInvariants(q);
    });

    test('multiple payers: payer also ower and not, pairwise in proportion '
        'to paid', () async {
      final p = await QaPhone.create();
      addTearDown(p.dispose);
      final t = await p.group(['Sam', 'Priya', 'Dev'], simplify: false);
      final ids = t.m.values.toList()..sort();
      final a = ids[0], b = ids[1], c = ids[2], d = ids[3];
      // a paid 600, b paid 300 of 900; owed by c and d only (payers not owers).
      await p.add(
        t.g,
        total: 900,
        paidBy: spec(SplitMethod.exact, {a: 600, b: 300}),
        owedBy: eq([c, d]),
      );
      expect(p.transfers(t.g), [
        Transfer(from: c, to: a, amount: 300, currency: 'INR'),
        Transfer(from: c, to: b, amount: 150, currency: 'INR'),
        Transfer(from: d, to: a, amount: 300, currency: 'INR'),
        Transfer(from: d, to: b, amount: 150, currency: 'INR'),
      ]);
      // Equal among payers of an odd total, payer also ower, percent payers.
      final e = await p.add(
        t.g,
        total: 1001,
        paidBy: eq([c, a]),
        owedBy: eq([a, b, c, d]),
      );
      expect(p.paid(e), {a: 501, c: 500});
      final f = await p.add(
        t.g,
        total: 1000,
        paidBy: spec(SplitMethod.percent, {a: 3333, b: 3333, c: 3334}),
        owedBy: spec(SplitMethod.shares, {d: 1}),
      );
      expect(p.paid(f), {a: 333, b: 333, c: 334});
      final h = await p.add(
        t.g,
        total: 1000,
        paidBy: spec(SplitMethod.shares, {a: 1000, b: 1}),
        owedBy: eq([a, b]),
      );
      expect(p.paid(h), {a: 999, b: 1});
      expectMoneyInvariants(p);
    });
  });

  group('R42 amount reading and face value', () {
    final inr = Currencies.of('INR'), eur = Currencies.of('EUR');
    final kwd = Currencies.of('KWD'), jpy = Currencies.of('JPY');
    final usd = Currencies.of('USD');
    test(
      'grouped and decimal-comma texts read as the amount or not at all',
      () {
        expect(parseAmountInput('1,234.50', inr), 123450);
        expect(parseAmountInput('1,234.50', usd), 123450);
        expect(parseAmountInput('12,34,567', inr), 123456700);
        expect(parseAmountInput('1.234,50', eur), 123450);
        expect(parseAmountInput('12.345', kwd), 12345);
        expect(parseAmountInput('12.3456', kwd), isNull);
        expect(parseAmountInput('12.345', usd), isNull);
        expect(parseAmountInput('800.50', jpy), isNull);
        expect(parseAmountInput('1,000', jpy), 1000);
        expect(parseAmountInput('-30', inr), isNull);
        expect(parseSignedAmountInput('−30', inr), -3000);
        expect(parseAmountInput('999,999,999.99', usd), Money.maxMinor);
        expect(parseAmountInput('1,000,000,000.00', usd), isNull);
        expect(parseAmountInput('99,999,999,999', jpy), Money.maxMinor);
        expect(parseAmountInput('99,999,999.999', kwd), Money.maxMinor);
      },
    );

    test('sameFaceValue: every JPY/INR/KWD amount moves and back exactly or '
        'not at all', () {
      final r = Random(42);
      final cs = [inr, jpy, kwd, usd];
      for (var i = 0; i < 20000; i++) {
        final from = cs[r.nextInt(4)], to = cs[r.nextInt(4)];
        final minor = switch (r.nextInt(4)) {
          0 => r.nextInt(1000),
          1 => Money.maxMinor - r.nextInt(1000),
          _ => (r.nextDouble() * Money.maxMinor).floor(),
        };
        final v = sameFaceValue(minor, from, to);
        // Face value: minor / 10^digits equal, compared in integers.
        final lhs = BigInt.from(minor) * BigInt.from(to.minorPerMajor);
        if (v == null) {
          final exact = lhs % BigInt.from(from.minorPerMajor) == BigInt.zero;
          final fits =
              exact &&
              lhs ~/ BigInt.from(from.minorPerMajor) <=
                  BigInt.from(Money.maxMinor);
          expect(fits, isFalse, reason: '$minor ${from.code}->${to.code}');
        } else {
          expect(BigInt.from(v) * BigInt.from(from.minorPerMajor), lhs);
          expect(v, inInclusiveRange(0, Money.maxMinor));
          expect(sameFaceValue(v, to, from), minor);
        }
      }
    });
  });

  test('R42 MoneyFormat prints every minor digit up to 50 x maxMinor '
      '(USD, KWD, JPY, INR)', () {
    final r = Random(4242);
    String plain(int minor, Currency c) {
      final abs = minor.abs();
      final major = (abs ~/ c.minorPerMajor).toString();
      final groups = <String>[];
      for (var i = major.length; i > 0; i -= 3) {
        groups.insert(0, major.substring(i < 3 ? 0 : i - 3, i));
      }
      final frac = c.minorDigits == 0
          ? ''
          : '.${(abs % c.minorPerMajor).toString().padLeft(c.minorDigits, '0')}';
      return '${groups.join(',')}$frac';
    }

    for (final code in ['USD', 'KWD', 'JPY', 'INR']) {
      final c = Currencies.of(code);
      for (var i = 0; i < 5000; i++) {
        final minor = switch (i % 4) {
          0 => 50 * Money.maxMinor - r.nextInt(100000),
          1 => Money.maxMinor - r.nextInt(100000),
          _ => (r.nextDouble() * 50 * Money.maxMinor).floor(),
        };
        final text = MoneyFormat.format(-minor, code, locale: 'en_US');
        final digits = text.replaceAll(RegExp(r'[^0-9.,]'), '');
        final want = plain(minor, c);
        if (code == 'INR' && minor % 100 == 0) {
          expect(digits, want.substring(0, want.length - 3), reason: '$minor');
        } else {
          expect(digits, want, reason: '$code $minor -> $text');
        }
        expect(text.startsWith(MoneyFormat.minusSign), isTrue);
      }
    }
  });
}
