// QA MONEY: several payers on the payer side (exact, equal among payers,
// percent, shares), payer who is / is not an ower, and the pairwise
// ("original") view splitting each debt in proportion to what was paid.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';

import 'money_harness.dart';

void main() {
  late QaPhone p;
  late GroupId g;
  late MemberId me, sam, priya, dev;

  setUp(() async {
    p = await QaPhone.create();
    final t = await p.group(['Sam', 'Priya', 'Dev'], simplify: false);
    g = t.g;
    me = t.m['me']!;
    sam = t.m['Sam']!;
    priya = t.m['Priya']!;
    dev = t.m['Dev']!;
    // Sequential ids: me < sam < priya < dev.
    expect([me, sam, priya, dev], orderedEquals([me, sam, priya, dev]..sort()));
  });
  tearDown(() => p.dispose());

  Transfer tr(MemberId from, MemberId to, int amount, [String cur = 'INR']) =>
      Transfer(from: from, to: to, amount: amount, currency: cur);

  test('exact payers, payer also an ower', () async {
    final id = await p.add(
      g,
      total: 9000,
      paidBy: spec(SplitMethod.exact, {me: 6000, sam: 3000}),
      owedBy: eq([me, sam, priya]),
    );
    expect(p.paid(id), {me: 6000, sam: 3000});
    expect(p.nets(g), {
      'INR': {me: 3000, priya: -3000},
    });
    // Pairwise: every 3000 share splits 2:1 over the payers, so sam owes me
    // 2000 for his and I owe sam 1000 for mine (netted: sam->me 1000) even
    // though sam's net is zero.
    expect(
      p.transfers(g),
      [tr(sam, me, 1000), tr(priya, me, 2000), tr(priya, sam, 1000)]..sort(
        (x, y) => x.from.compareTo(y.from) != 0
            ? x.from.compareTo(y.from)
            : x.to.compareTo(y.to),
      ),
    );
    expectMoneyInvariants(p);
  });

  test('exact payers that do not add up are refused', () async {
    await expectLater(
      p.add(
        g,
        total: 9000,
        paidBy: spec(SplitMethod.exact, {me: 6000, sam: 2000}),
        owedBy: eq([me, sam]),
      ),
      throwsA(
        isA<LedgerException>().having(
          (e) => e.code,
          'code',
          LedgerErrorCode.invalidSplit,
        ),
      ),
    );
  });

  test('equal among payers: the odd unit goes to the lowest id', () async {
    final id = await p.add(
      g,
      total: 1001,
      paidBy: eq([priya, me]),
      owedBy: eq([sam]),
    );
    expect(p.paid(id), {me: 501, priya: 500});
    expect(p.nets(g)['INR'], {me: 501, sam: -1001, priya: 500});
    expect(p.transfers(g), [tr(sam, me, 501), tr(sam, priya, 500)]);
    expectMoneyInvariants(p);
  });

  test('percent and shares on the payer side', () async {
    final a = await p.add(
      g,
      total: 10000,
      paidBy: spec(SplitMethod.percent, {me: 2500, sam: 7500}),
      owedBy: eq([priya, dev]),
    );
    expect(p.paid(a), {me: 2500, sam: 7500});
    final b = await p.add(
      g,
      total: 999,
      paidBy: spec(SplitMethod.shares, {me: 1, sam: 2}),
      owedBy: eq([me, sam, priya]),
    );
    expect(p.paid(b), {me: 333, sam: 666});
    expectMoneyInvariants(p);
  });

  test(
    'payer who is not an ower: owers owe the payers in proportion',
    () async {
      await p.add(
        g,
        total: 9000,
        paidBy: spec(SplitMethod.exact, {me: 6000, sam: 3000}),
        owedBy: eq([priya, dev]),
      );
      expect(
        p.transfers(g),
        [
          tr(priya, me, 3000),
          tr(priya, sam, 1500),
          tr(dev, me, 3000),
          tr(dev, sam, 1500),
        ]..sort(
          (x, y) => x.from.compareTo(y.from) != 0
              ? x.from.compareTo(y.from)
              : x.to.compareTo(y.to),
        ),
      );
      expectMoneyInvariants(p);
    },
  );

  test('SPEC 6.3 vector through the ledger (simplify off)', () async {
    // a = me, b = sam, c = priya.
    await p.add(
      g,
      total: 9000,
      paidBy: one(me, 9000),
      owedBy: eq([me, sam, priya]),
    );
    await p.add(
      g,
      total: 3000,
      paidBy: one(sam, 3000),
      owedBy: spec(SplitMethod.exact, {me: 1500, sam: 1500}),
    );
    expect(p.transfers(g), [tr(sam, me, 1500), tr(priya, me, 3000)]);
    expectMoneyInvariants(p);
  });

  test('awkward multi-payer remainders still settle to the unit', () async {
    // 3 payers, 4 owers, prime total: the pairwise rows and columns must
    // both stay exact.
    for (final total in [7, 101, 9973, 999999937]) {
      await p.add(
        g,
        total: total,
        paidBy: spec(SplitMethod.shares, {me: 3, sam: 5, priya: 7}),
        owedBy: spec(SplitMethod.shares, {me: 2, sam: 3, priya: 5, dev: 11}),
      );
      expectMoneyInvariants(p, reason: 'total $total');
    }
    // And the same with simplify on.
    await p.ledger.updateGroup(g, const GroupPatch(simplifyDebts: true));
    await pumpEventQueue();
    expectMoneyInvariants(p, reason: 'simplified');
  });

  test(
    'pairwise is netted per pair: A->B 30 and B->A 10 become A->B 20',
    () async {
      await p.add(g, total: 60, paidBy: one(me, 60), owedBy: eq([me, sam]));
      await p.add(g, total: 20, paidBy: one(sam, 20), owedBy: eq([me, sam]));
      expect(p.transfers(g), [tr(sam, me, 20)]);
      expectMoneyInvariants(p);
    },
  );
}
