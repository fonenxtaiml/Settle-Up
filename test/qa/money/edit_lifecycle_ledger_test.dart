// QA MONEY: edits of amount / split / payer / currency, delete, restore,
// edit after delete then restore, updatePayment, and the SPEC 7.2 conflict
// table across two phones. Nets are re-checked after every command.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';

import 'money_harness.dart';

void main() {
  late QaPhone p;
  late GroupId g;
  late MemberId me, sam, priya;

  setUp(() async {
    p = await QaPhone.create();
    final t = await p.group(['Sam', 'Priya']);
    g = t.g;
    me = t.m['me']!;
    sam = t.m['Sam']!;
    priya = t.m['Priya']!;
  });
  tearDown(() => p.dispose());

  ExpenseDraft draft({
    int total = 9000,
    String currency = 'INR',
    SplitSpec? paidBy,
    SplitSpec? owedBy,
    String description = 'Dinner',
  }) => ExpenseDraft(
    groupId: g,
    description: description,
    total: total,
    currency: currency,
    paidBy: paidBy ?? one(me, total),
    owedBy: owedBy ?? eq([me, sam, priya]),
    category: 'food.dining',
    date: utcFromMillis(kBaseMs),
  );

  Future<void> run(Future<void> Function() cmd, String what) async {
    p.tick();
    await cmd();
    await pumpEventQueue();
    expectMoneyInvariants(p, reason: what);
  }

  test(
    'edit amount, split, payer and currency; each step recomputed',
    () async {
      final id = await p.add(
        g,
        total: 9000,
        paidBy: one(me, 9000),
        owedBy: eq([me, sam, priya]),
      );
      expect(p.nets(g), {
        'INR': {me: 6000, sam: -3000, priya: -3000},
      });

      await run(
        () => p.ledger.updateExpense(id, draft(total: 12000)),
        'amount',
      );
      expect(p.nets(g)['INR'], {me: 8000, sam: -4000, priya: -4000});

      await run(
        () => p.ledger.updateExpense(
          id,
          draft(
            total: 12000,
            owedBy: spec(SplitMethod.exact, {sam: 2000, priya: 10000}),
          ),
        ),
        'split',
      );
      expect(p.nets(g)['INR'], {me: 12000, sam: -2000, priya: -10000});

      await run(
        () => p.ledger.updateExpense(
          id,
          draft(
            total: 12000,
            paidBy: one(sam, 12000),
            owedBy: spec(SplitMethod.exact, {sam: 2000, priya: 10000}),
          ),
        ),
        'payer',
      );
      expect(p.nets(g)['INR'], {sam: 10000, priya: -10000});

      await run(
        () => p.ledger.updateExpense(
          id,
          draft(
            total: 12000,
            currency: 'USD',
            paidBy: one(sam, 12000),
            owedBy: spec(SplitMethod.exact, {sam: 2000, priya: 10000}),
          ),
        ),
        'currency',
      );
      expect(p.nets(g), {
        'USD': {sam: 10000, priya: -10000},
      }, reason: 'no INR left behind after a currency change');
      expect(p.state.expense(id)!.money.currency, 'USD');
    },
  );

  test('delete, restore, edit while deleted, restore keeps the edit', () async {
    final id = await p.add(
      g,
      total: 9000,
      paidBy: one(me, 9000),
      owedBy: eq([me, sam, priya]),
    );
    await run(() => p.ledger.deleteExpense(id), 'delete');
    expect(p.nets(g), isEmpty);
    expect(p.transfers(g), isEmpty);
    expect(p.overall().net, isEmpty);

    await run(() => p.ledger.restoreExpense(id), 'restore');
    expect(p.nets(g)['INR'], {me: 6000, sam: -3000, priya: -3000});

    await run(() => p.ledger.deleteExpense(id), 'delete again');
    await run(
      () => p.ledger.updateExpense(id, draft(total: 3000)),
      'edit while deleted',
    );
    expect(p.nets(g), isEmpty, reason: 'a deleted expense stays out');
    await run(() => p.ledger.restoreExpense(id), 'restore after edit');
    expect(p.nets(g)['INR'], {
      me: 2000,
      sam: -1000,
      priya: -1000,
    }, reason: 'restore brings back the latest edit');
  });

  test(
    'payments: record, updatePayment amount and direction, delete',
    () async {
      await p.add(
        g,
        total: 9000,
        paidBy: one(me, 9000),
        owedBy: eq([me, sam, priya]),
      );
      final pay = await p.pay(g, from: sam, to: me, amount: 1000);
      expectMoneyInvariants(p);
      expect(p.nets(g)['INR'], {me: 5000, sam: -2000, priya: -3000});

      PaymentDraft pd(
        MemberId from,
        MemberId to,
        int amount, [
        String cur = 'INR',
      ]) => PaymentDraft(
        groupId: g,
        from: from,
        to: to,
        amount: amount,
        currency: cur,
        method: PaymentMethod.upi,
        date: utcFromMillis(kBaseMs),
      );

      await run(() => p.ledger.updatePayment(pay, pd(sam, me, 3000)), 'amount');
      expect(p.nets(g)['INR'], {me: 3000, priya: -3000});

      await run(
        () => p.ledger.updatePayment(pay, pd(priya, me, 3000)),
        'payer',
      );
      expect(p.nets(g)['INR'], {me: 3000, sam: -3000});

      await run(
        () => p.ledger.updatePayment(pay, pd(priya, me, 3000, 'USD')),
        'currency',
      );
      expect(p.nets(g), {
        'INR': {me: 6000, sam: -3000, priya: -3000},
        'USD': {me: -3000, priya: 3000},
      });

      await expectLater(
        p.ledger.updatePayment(pay, pd(me, me, 10)),
        throwsA(isA<LedgerException>()),
      );
      await expectLater(
        p.ledger.updateExpense(pay, draft()),
        throwsA(isA<LedgerException>()),
      );

      await run(() => p.ledger.deleteExpense(pay), 'delete payment');
      expect(p.nets(g), {
        'INR': {me: 6000, sam: -3000, priya: -3000},
      });
    },
  );

  group('SPEC 7.2 conflict table across two phones', () {
    late QaPhone q;
    late ExpenseId id;

    setUp(() async {
      q = await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb');
      await shareGroup(p, q, g);
      id = await p.add(
        g,
        total: 9000,
        paidBy: one(me, 9000),
        owedBy: eq([me, sam, priya]),
      );
      await syncBoth(p, q, g);
      expect(q.state.toCanonicalJson(), p.state.toCanonicalJson());
    });
    tearDown(() => q.dispose());

    Future<void> converge() async {
      await syncBoth(p, q, g);
      expect(
        q.state.toCanonicalJson(),
        p.state.toCanonicalJson(),
        reason: 'phones converge',
      );
      expect(q.nets(g), p.nets(g));
      expect(q.transfers(g), p.transfers(g));
      expectMoneyInvariants(p);
      expectMoneyInvariants(q);
    }

    test('A edits the description, B edits the amount: both kept', () async {
      p.tick();
      await p.ledger.updateExpense(
        id,
        draft(description: 'Dinner at Thalassa'),
      );
      q.tick(5000);
      await q.ledger.updateExpense(id, draft(total: 6000));
      await converge();
      final e = p.state.expense(id)!;
      expect(e.description, 'Dinner at Thalassa');
      expect(e.money.total, 6000);
    });

    test('both edit the money block: higher HLC wins whole', () async {
      p.tick(1000);
      await p.ledger.updateExpense(
        id,
        draft(total: 6000, owedBy: spec(SplitMethod.exact, {sam: 6000})),
      );
      q.tick(9000); // later wall clock -> higher HLC
      await q.ledger.updateExpense(
        id,
        draft(total: 3000, owedBy: spec(SplitMethod.percent, {priya: 10000})),
      );
      await converge();
      final m = p.state.expense(id)!.money;
      expect(m.total, 3000);
      expect(m.owed, {
        priya: 3000,
      }, reason: 'never a mix of the two money blocks');
      expect(m.owedBy.method, SplitMethod.percent);
    });

    test(
      'edit vs delete: deleted; restore brings back the latest edit',
      () async {
        p.tick();
        await p.ledger.deleteExpense(id);
        q.tick(3000);
        await q.ledger.updateExpense(id, draft(total: 4500));
        await converge();
        expect(p.state.expense(id)!.isDeleted, isTrue);
        expect(p.nets(g), isEmpty);
        p.tick(10000);
        await p.ledger.restoreExpense(id);
        await converge();
        expect(p.nets(g)['INR'], {me: 3000, sam: -1500, priya: -1500});
      },
    );

    test('delete vs later restore: higher HLC on deletedAt wins', () async {
      // q (offline) deletes and restores early; p deletes later.
      q.tick(2000);
      await q.ledger.deleteExpense(id);
      q.tick(1000);
      await q.ledger.restoreExpense(id);
      p.tick(10000);
      await p.ledger.deleteExpense(id);
      await converge();
      expect(p.state.expense(id)!.isDeleted, isTrue, reason: 'p deleted last');
      // Now q restores with a later clock.
      q.tick(20000);
      await q.ledger.restoreExpense(id);
      await converge();
      expect(p.state.expense(id)!.isDeleted, isFalse);
      expect(p.nets(g)['INR'], {me: 6000, sam: -3000, priya: -3000});
    });

    test('two payments for the same debt are both kept', () async {
      await p.pay(g, from: sam, to: me, amount: 3000);
      await q.pay(g, from: sam, to: me, amount: 3000);
      await converge();
      final payments = p.gs(g).liveExpenses.where((e) => e.isPayment).toList();
      expect(payments, hasLength(2));
      // Over-paid: Sam is now owed 3000 by me.
      expect(p.nets(g)['INR'], {sam: 3000, priya: -3000});
    });

    test('concurrent merges A->B and B->A resolve to the smaller id', () async {
      p.tick();
      await p.ledger.mergeMembers(g, from: sam, into: priya);
      q.tick();
      await q.ledger.mergeMembers(g, from: priya, into: sam);
      await converge();
      final small = sam.compareTo(priya) < 0 ? sam : priya;
      expect(p.gs(g).resolve(sam), small);
      expect(p.gs(g).resolve(priya), small);
      expect(p.nets(g)['INR'], {me: 6000, small: -6000});
    });
  });
}
