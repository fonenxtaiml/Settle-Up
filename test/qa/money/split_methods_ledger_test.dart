// QA MONEY: every split method through Ledger.addExpense and the providers
// (SPEC 6.1 vectors plus the charter's edge cases).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';

import 'money_harness.dart';

Matcher throwsLedger(LedgerErrorCode code) =>
    throwsA(isA<LedgerException>().having((e) => e.code, 'code', code));

// Member ids chosen so that a < b < c by String.compareTo, while the members
// are CREATED in the order c, a, b (insertion order must not matter).
const MemberId a = '00000000-0000-7000-8000-00000000a001';
const MemberId b = '00000000-0000-7000-8000-00000000b001';
const MemberId c = '00000000-0000-7000-8000-00000000c001';

void main() {
  late QaPhone p;
  late GroupId g;
  late MemberId me;

  Future<void> addAbc(QaPhone phone, GroupId group) async {
    for (final (id, name) in [(c, 'Cara'), (a, 'Ann'), (b, 'Ben')]) {
      phone.ids.queue([id]);
      await phone.ledger.addMember(
        group,
        displayName: name,
        personId: 'person-$name',
      );
    }
  }

  setUp(() async {
    p = await QaPhone.create();
    final t = await p.group(const []);
    g = t.g;
    me = t.m['me']!;
    await addAbc(p, g);
    expect(p.gs(g).members.keys, containsAll([a, b, c]));
  });
  tearDown(() => p.dispose());

  Future<Map<MemberId, int>> owed(
    int total,
    SplitSpec owedBy, {
    String currency = 'INR',
    SplitSpec? paidBy,
  }) async {
    final id = await p.add(
      g,
      total: total,
      currency: currency,
      paidBy: paidBy ?? one(me, total),
      owedBy: owedBy,
    );
    final shares = p.owed(id);
    expect(
      shares.values.fold(0, (x, y) => x + y),
      total,
      reason: 'sum of shares == total',
    );
    expectMoneyInvariants(p, reason: 'after $owedBy');
    return shares;
  }

  group('SPEC 6.1 vectors through Ledger.addExpense', () {
    test('1000 equal a,b,c', () async {
      expect(await owed(1000, eq([a, b, c])), {a: 334, b: 333, c: 333});
    });

    test('100 equal c,a,b (shuffled insertion order)', () async {
      expect(await owed(100, eq([c, a, b])), {a: 34, b: 33, c: 33});
    });

    test('1000 percent 3333/3333/3334', () async {
      expect(
        await owed(
          1000,
          spec(SplitMethod.percent, {c: 3334, b: 3333, a: 3333}),
        ),
        {a: 333, b: 333, c: 334},
      );
    });

    test('1000 shares a 2, b 1', () async {
      expect(await owed(1000, spec(SplitMethod.shares, {b: 1, a: 2})), {
        a: 667,
        b: 333,
      });
    });

    test('6000 adjustment a +1000, b 0, c 0', () async {
      expect(
        await owed(6000, spec(SplitMethod.adjustment, {c: 0, b: 0, a: 1000})),
        {a: 2667, b: 1667, c: 1666},
      );
    });

    test('6000 exact 2000/2000/1550 is rejected (remaining 450)', () async {
      await expectLater(
        p.add(
          g,
          total: 6000,
          paidBy: one(me, 6000),
          owedBy: spec(SplitMethod.exact, {a: 2000, b: 2000, c: 1550}),
        ),
        throwsLedger(LedgerErrorCode.invalidSplit),
      );
      expect(p.gs(g).liveExpenses, isEmpty);
    });

    test('6000 exact 2000/2000/2500 is rejected (remaining -500)', () async {
      await expectLater(
        p.add(
          g,
          total: 6000,
          paidBy: one(me, 6000),
          owedBy: spec(SplitMethod.exact, {a: 2000, b: 2000, c: 2500}),
        ),
        throwsLedger(LedgerErrorCode.invalidSplit),
      );
    });

    test('1 equal a,b,c -> a 1', () async {
      expect(await owed(1, eq([c, b, a])), {a: 1});
    });

    test('500 JPY equal a,b,c', () async {
      expect(await owed(500, eq([a, b, c]), currency: 'JPY'), {
        a: 167,
        b: 167,
        c: 166,
      });
    });

    test('6000 adjustment a -7000, b 0 is rejected', () async {
      await expectLater(
        p.add(
          g,
          total: 6000,
          paidBy: one(me, 6000),
          owedBy: spec(SplitMethod.adjustment, {a: -7000, b: 0}),
        ),
        throwsLedger(LedgerErrorCode.invalidSplit),
      );
    });
  });

  group('charter edge cases', () {
    test(
      '1 minor unit over 3 goes to the lowest id, not the first created',
      () async {
        // c was created first; a has the lowest id.
        expect(await owed(1, eq([c, a, b])), {a: 1});
        expect(await owed(2, eq([b, c, a])), {a: 1, b: 1});
      },
    );

    test(
      'Money.maxMinor with 50 members (equal, percent, shares, adjust)',
      () async {
        final t = await p.group([for (var i = 0; i < 49; i++) 'P$i']);
        final ids = t.m.values.toList()..sort();
        expect(ids, hasLength(50));
        final id = await p.add(
          t.g,
          total: Money.maxMinor,
          paidBy: one(t.m['me']!, Money.maxMinor),
          owedBy: eq(ids.reversed),
        );
        final shares = p.owed(id);
        expect(shares.values.fold(0, (x, y) => x + y), Money.maxMinor);
        // 99,999,999,999 / 50 = 1,999,999,999 r 49: the 49 lowest ids
        // get +1.
        for (var i = 0; i < 49; i++) {
          expect(shares[ids[i]], 2000000000);
        }
        expect(shares[ids[49]], 1999999999);

        final pct = await p.add(
          t.g,
          total: Money.maxMinor,
          paidBy: eq(ids),
          owedBy: spec(SplitMethod.percent, {for (final m in ids) m: 200}),
        );
        expect(p.owed(pct).values.fold(0, (x, y) => x + y), Money.maxMinor);

        final sh = await p.add(
          t.g,
          total: Money.maxMinor,
          paidBy: spec(SplitMethod.shares, {
            for (var i = 0; i < 50; i++) ids[i]: 1000 - i,
          }),
          owedBy: spec(SplitMethod.shares, {
            for (var i = 0; i < 50; i++) ids[i]: i + 1,
          }),
        );
        expect(p.paid(sh).values.fold(0, (x, y) => x + y), Money.maxMinor);
        expect(p.owed(sh).values.fold(0, (x, y) => x + y), Money.maxMinor);

        final adj = await p.add(
          t.g,
          total: Money.maxMinor,
          paidBy: one(ids.last, Money.maxMinor),
          owedBy: spec(SplitMethod.adjustment, {
            for (var i = 0; i < 50; i++) ids[i]: i.isEven ? 1000 : -1000,
          }),
        );
        expect(p.owed(adj).values.fold(0, (x, y) => x + y), Money.maxMinor);
        expectMoneyInvariants(p, reason: '50 members at maxMinor');
      },
    );

    test('a total above Money.maxMinor or below 1 is refused', () async {
      for (final total in [0, -1, Money.maxMinor + 1]) {
        await expectLater(
          p.add(g, total: total, paidBy: one(me, total), owedBy: eq([a])),
          throwsLedger(LedgerErrorCode.invalidInput),
        );
      }
    });

    test('percent 3333/3333/3334 on tiny totals', () async {
      final s = spec(SplitMethod.percent, {a: 3333, b: 3333, c: 3334});
      expect(await owed(1, s), {c: 1});
      // 6666/6666/6668 remainders: c, then the a/b tie goes to a.
      expect(await owed(2, s), {a: 1, c: 1});
      expect(await owed(3, s), {a: 1, b: 1, c: 1});
      expect(await owed(10, s), {a: 3, b: 3, c: 4});
    });

    test('shares 1000:1', () async {
      final s = spec(SplitMethod.shares, {a: 1000, b: 1});
      expect(await owed(1001, s), {a: 1000, b: 1});
      expect(await owed(1000, s), {a: 999, b: 1});
      expect(await owed(1, s), {a: 1});
      // 99,999,999,999 x 1000 / 1001 = 99,900,099,899 r 101 and
      // 99,999,999,999 / 1001 = 99,900,099 r 900: b has the larger
      // remainder and takes the leftover unit.
      expect(await owed(Money.maxMinor, s), {a: 99900099899, b: 99900100});
    });

    test('adjustment that makes rest exactly 0', () async {
      expect(
        await owed(
          3000,
          spec(SplitMethod.adjustment, {a: 1000, b: 1000, c: 1000}),
        ),
        {a: 1000, b: 1000, c: 1000},
      );
      expect(await owed(3000, spec(SplitMethod.adjustment, {a: 3000, b: 0})), {
        a: 3000,
      });
    });

    test('valid negative adjustment', () async {
      // rest = 7000 -> 2334/2333/2333, then a -1000.
      expect(
        await owed(6000, spec(SplitMethod.adjustment, {a: -1000, b: 0, c: 0})),
        {a: 1334, b: 2333, c: 2333},
      );
      // A share brought to exactly zero is dropped, not stored as 0.
      expect(
        await owed(3000, spec(SplitMethod.adjustment, {a: -1500, b: 0, c: 0})),
        {b: 1500, c: 1500},
      );
    });

    test('zero-weight participants are dropped from owed', () async {
      expect(
        await owed(1000, spec(SplitMethod.percent, {a: 10000, b: 0, c: 0})),
        {a: 1000},
      );
      expect(await owed(1000, spec(SplitMethod.exact, {a: 1000, b: 0})), {
        a: 1000,
      });
      // shares weight 0 is invalid by SPEC 6.1 (each 1..1000).
      await expectLater(
        p.add(
          g,
          total: 1000,
          paidBy: one(me, 1000),
          owedBy: spec(SplitMethod.shares, {a: 1, b: 0}),
        ),
        throwsLedger(LedgerErrorCode.invalidSplit),
      );
    });

    test('KWD (3 digits) and INR', () async {
      expect(await owed(1000, eq([a, b, c]), currency: 'KWD'), {
        a: 334,
        b: 333,
        c: 333,
      });
      expect(await owed(12345, eq([a, b]), currency: 'KWD'), {
        a: 6173,
        b: 6172,
      });
      expect(await owed(100000, eq([a, b, c]), currency: 'INR'), {
        a: 33334,
        b: 33333,
        c: 33333,
      });
      final nets = p.nets(g);
      expect(nets.keys, containsAll(['INR', 'KWD']));
    });

    test('referencing a member of another group is refused', () async {
      final other = await p.group(['Zed']);
      await expectLater(
        p.add(
          g,
          total: 100,
          paidBy: one(me, 100),
          owedBy: eq([other.m['Zed']!]),
        ),
        throwsLedger(LedgerErrorCode.memberNotFound),
      );
    });

    test('seeded property: random specs always sum to the total', () async {
      final r = Random(20261109);
      final members = [me, a, b, c];
      for (var i = 0; i < 150; i++) {
        final total =
            1 +
            (r.nextBool()
                ? r.nextInt(1000)
                : (r.nextDouble() * Money.maxMinor).floor());
        final who = (members.toList()..shuffle(r)).take(1 + r.nextInt(4));
        final method = SplitMethod.values[r.nextInt(5)];
        final values = <MemberId, int>{};
        switch (method) {
          case SplitMethod.equal:
            for (final m in who) {
              values[m] = 1;
            }
          case SplitMethod.exact:
            final parts = {for (final m in who) m: 1 + r.nextInt(100)};
            final shares = _apportion(total, parts);
            values.addAll(shares);
          case SplitMethod.percent:
            values.addAll(_apportion(10000, {for (final m in who) m: 1}));
          case SplitMethod.shares:
            for (final m in who) {
              values[m] = 1 + r.nextInt(1000);
            }
          case SplitMethod.adjustment:
            for (final m in who) {
              values[m] =
                  _below(r, total ~/ (who.length * 2) + 1) *
                  (r.nextBool() ? 1 : -1);
            }
            if (values.values.fold(0, (x, y) => x + y) > total) continue;
        }
        try {
          await owed(total, SplitSpec(method, values));
        } on LedgerException catch (e) {
          // Only a negative final adjustment share may be refused.
          expect(method, SplitMethod.adjustment, reason: '$e');
        }
      }
    });
  });
}

Map<MemberId, int> _apportion(int total, Map<MemberId, int> w) {
  final sum = w.values.fold(0, (x, y) => x + y);
  final out = <MemberId, int>{};
  var left = total;
  final keys = w.keys.toList();
  for (var i = 0; i < keys.length; i++) {
    final v = i == keys.length - 1 ? left : total * w[keys[i]]! ~/ sum;
    out[keys[i]] = v;
    left -= v;
  }
  return out;
}

/// Random.nextInt stops at 2^32; Money.maxMinor is above it.
int _below(Random r, int n) =>
    n <= 1 << 32 ? r.nextInt(n) : (r.nextDouble() * n).floor().clamp(0, n - 1);
