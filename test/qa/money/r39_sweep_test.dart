// QA MONEY round 39: final full regression sweep of money correctness on
// the integrated build, through the real Ledger(MemoryOpStore) and the
// Riverpod providers. The money code itself is unchanged since round 29;
// what changed under it is how own ops are stamped when this phone's
// clock ran ahead (DATA-R29-01, DATA-R31-01, DATA-R32-01: the clock is set
// back past a 5-day lead, own stamps far ahead are followed). New angles:
//  * an edit, delete, restore or updatePayment made after the phone's
//    clock ran days ahead and was set back always shows at once on that
//    phone (a local write is never lost to the phone's own earlier stamp),
//    and both phones converge on the same nets once clocks agree;
//  * seeded command fuzz over two phones whose wall clocks jump forward
//    and back by up to 10 days, re-checking every money invariant after
//    each command plus "what I just saved is what I see";
//  * a fresh pass over the charter's split vectors at the edges (1 minor
//    unit over 3, Money.maxMinor over 50 members, shares 1000:1,
//    adjustments making the rest exactly 0) with the stamps set back.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';

import 'money_harness.dart';

const int _day = 24 * 60 * 60 * 1000;
const _currencies = ['INR', 'JPY', 'KWD', 'USD'];
const _offsets = [
  0,
  0,
  -_day,
  -_day ~/ 2,
  _day,
  5 * _day ~/ 2,
  4 * _day,
  11 * _day ~/ 2,
];

void main() {
  group('R39 money edits after the clock ran ahead and was set back', () {
    for (final lead in [2 * _day, 6 * _day, 9 * _day, 30 * _day]) {
      test('lead ${lead ~/ _day} days: the next edit wins on this phone and '
          'after sync', () async {
        final p = await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa');
        final q = await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb');
        addTearDown(() async {
          await p.dispose();
          await q.dispose();
        });
        final t = await p.group(['Sam', 'Priya']);
        final g = t.g;
        await shareGroup(p, q, g);
        final me = t.m['me']!;
        final sam = t.m['Sam']!;
        final priya = t.m['Priya']!;
        final e = await p.add(
          g,
          total: 30000,
          paidBy: one(me, 30000),
          owedBy: eq([me, sam, priya]),
        );
        final pay = await p.pay(g, from: sam, to: me, amount: 5000);
        await syncBoth(p, q, g);

        // The clock runs ahead: an edit and a payment change are stamped
        // that far ahead.
        p.tick(lead);
        await p.ledger.updateExpense(
          e,
          _draft(g, 'ahead', 60000, one(me, 60000), eq([me, sam, priya])),
        );
        await p.ledger.updatePayment(pay, _payment(g, sam, me, 7000));
        await pumpEventQueue();
        expect(p.state.expense(e)!.money.total, 60000);
        expectMoneyInvariants(p, reason: 'ahead');

        // Set back to the real time; the next edits must win here at once.
        p.tick(-lead);
        await p.ledger.updateExpense(
          e,
          _draft(g, 'fixed', 90000, one(priya, 90000), eq([me, sam])),
        );
        await p.ledger.updatePayment(pay, _payment(g, priya, sam, 1234));
        await pumpEventQueue();
        final now = p.state.expense(e)!;
        expect(now.description, 'fixed');
        expect(now.money.total, 90000);
        expect(now.money.paid, {priya: 90000});
        expect(now.money.owed, {me: 45000, sam: 45000});
        final pm = p.state.expense(pay)!.money;
        expect(pm.total, 1234);
        expect(pm.paid, {priya: 1234});
        expect(pm.owed, {sam: 1234});
        expectMoneyInvariants(p, reason: 'set back');
        // A payment adds to the payer's net: priya +90000 +1234, me -45000,
        // sam -45000 -1234.
        expect(p.nets(g), {
          'INR': {priya: 91234, me: -45000, sam: -46234},
        });

        // Delete, then restore, then edit again: each shows at once.
        p.tick(10);
        await p.ledger.deleteExpense(e);
        await pumpEventQueue();
        expect(p.state.expense(e)!.isDeleted, isTrue);
        expect(p.nets(g), {
          'INR': {priya: 1234, sam: -1234},
        });
        p.tick(10);
        await p.ledger.restoreExpense(e);
        await pumpEventQueue();
        expect(p.state.expense(e)!.isDeleted, isFalse);
        expect(p.state.expense(e)!.money.total, 90000);
        expectMoneyInvariants(p, reason: 'restore');

        // Once the clocks agree everything reaches the other phone and both
        // show the same money.
        q.tick(lead + _day);
        p.tick(lead + _day);
        await syncBoth(p, q, g);
        await syncBoth(p, q, g);
        expect(q.state.toCanonicalJson(), p.state.toCanonicalJson());
        expect(q.nets(g), p.nets(g));
        expect(q.state.expense(e)!.description, 'fixed');
        expect(q.state.expense(pay)!.money.total, 1234);
        expectMoneyInvariants(q, reason: 'peer');
      });
    }

    test('a peer edit made after the far-ahead edit (in real time) is kept '
        'when this phone edits again', () async {
      final p = await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa');
      final q = await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb');
      addTearDown(() async {
        await p.dispose();
        await q.dispose();
      });
      final t = await p.group(['Sam']);
      final g = t.g;
      await shareGroup(p, q, g);
      final me = t.m['me']!;
      final sam = t.m['Sam']!;
      final e = await p.add(
        g,
        total: 1000,
        paidBy: one(me, 1000),
        owedBy: eq([me, sam]),
      );
      await syncBoth(p, q, g);
      p.tick(6 * _day);
      await p.ledger.updateExpense(
        e,
        _draft(g, 'p ahead', 2000, one(me, 2000), eq([me, sam])),
      );
      p.tick(-6 * _day);
      await syncBoth(p, q, g);
      // Sam edits after seeing it: his edit is stamped after it.
      q.tick(1000);
      await q.ledger.updateExpense(
        e,
        _draft(g, 'q later', 3000, one(sam, 3000), eq([me, sam])),
      );
      await syncBoth(p, q, g);
      expect(p.state.expense(e)!.description, 'q later');
      expect(p.nets(g), {
        'INR': {sam: 1500, me: -1500},
      });
      // Then Alex edits again: his edit wins on both.
      p.tick(1000);
      await p.ledger.updateExpense(
        e,
        _draft(g, 'p last', 4000, one(me, 4000), eq([me, sam])),
      );
      await pumpEventQueue();
      expect(p.state.expense(e)!.description, 'p last');
      await syncBoth(p, q, g);
      expect(q.state.expense(e)!.description, 'p last');
      expect(q.nets(g), {
        'INR': {me: 2000, sam: -2000},
      });
      expectMoneyInvariants(p);
      expectMoneyInvariants(q);
    });
  });

  group('R39 MONEY-R39-01 repro', () {
    test(
      'an edit is lost after a peer edited on top of this phone\'s stamp '
      'from a week ahead',
      () async {
        final alex = await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa');
        final sam = await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb');
        addTearDown(() async {
          await alex.dispose();
          await sam.dispose();
        });
        final t = await alex.group(['Sam']);
        final g = t.g;
        await shareGroup(alex, sam, g);
        final me = t.m['me']!;
        final s = t.m['Sam']!;
        final e = await alex.add(
          g,
          total: 10000,
          paidBy: one(me, 10000),
          owedBy: eq([me, s]),
        );
        await syncBoth(alex, sam, g);

        // Alex's date runs 7.5 days ahead; Sam's is one day ahead, within
        // the 2 days nearby discovery tolerates.
        alex.tick(15 * _day ~/ 2);
        sam.tick(_day);
        await alex.ledger.updateExpense(
          e,
          _draft(g, 'Taxi', 20000, one(me, 20000), eq([me, s])),
        );
        await syncBoth(alex, sam, g); // Sam accepts: 6.5 days ahead of him
        sam.tick(1000);
        await sam.ledger.updateExpense(
          e,
          _draft(g, 'Taxi and tip', 24000, one(me, 24000), eq([me, s])),
        );
        await syncBoth(alex, sam, g);
        expect(alex.state.expense(e)!.description, 'Taxi and tip');

        // Alex fixes his date and corrects the amount.
        alex.tick(-15 * _day ~/ 2);
        await alex.ledger.updateExpense(
          e,
          _draft(g, 'Taxi', 30000, one(me, 30000), eq([me, s])),
        );
        await pumpEventQueue();
        // What Alex just saved is what Alex sees, and Sam after a sync.
        expect(alex.state.expense(e)!.money.total, 30000);
        expect(alex.nets(g), {
          'INR': {me: 15000, s: -15000},
        });
        await syncBoth(alex, sam, g);
        expect(sam.state.expense(e)!.money.total, 30000);
        expectMoneyInvariants(alex);
        expectMoneyInvariants(sam);
      },
    );
  });

  group('R39 fuzz: two phones with wall clocks jumping days', () {
    for (final seed in [3901, 3902, 3903, 3904, 3905, 3906]) {
      test('seed $seed', () async {
        final r = Random(seed);
        final p = await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa');
        final q = await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb');
        addTearDown(() async {
          await p.dispose();
          await q.dispose();
        });
        final t = await p.group(['Sam', 'Priya', 'Dev']);
        final g = t.g;
        await shareGroup(p, q, g);
        await syncBoth(p, q, g);
        final ms = t.m.values.toList()..sort();
        final expenses = <ExpenseId>[];
        final payments = <ExpenseId>[];
        // Offsets of each phone's wall clock from real time.
        final offset = {p: 0, q: 0};
        // Each phone's wall clock (only the ticks below move it).
        final clock = {p: kBaseMs, q: kBaseMs};
        void setClock(QaPhone phone, int to) {
          phone.tick(to - clock[phone]!);
          clock[phone] = to;
        }

        var real = 0;
        var commands = 0;
        for (var step = 0; step < 80; step++) {
          final phone = r.nextBool() ? q : p;
          real += 1 + r.nextInt(60000);
          if (r.nextInt(6) == 0) {
            // Within the 7 days SPEC 7.1 adopts between any two clocks, and
            // past the 5-day lead so the factory sets the clock back
            // (MONEY-R39-01 covers a stamp more than 7 days ahead).
            offset[phone] = _offsets[r.nextInt(_offsets.length)];
          }
          // Put the phone's wall clock at real time + its offset.
          setClock(phone, kBaseMs + real + offset[phone]!);
          final cur = _currencies[r.nextInt(_currencies.length)];
          final total = 1 + r.nextInt(r.nextBool() ? 10 : 500000);
          ExpenseDraft draft() {
            final who = (ms.toList()..shuffle(r))
                .take(1 + r.nextInt(ms.length))
                .toList();
            return _draft(
              g,
              'E$step',
              total,
              SplitSpec.single(ms[r.nextInt(ms.length)], total),
              SplitSpec.equal(who),
              currency: cur,
            );
          }

          var what = '';
          try {
            switch (r.nextInt(10)) {
              case 0 || 1 || 2:
                what = 'add';
                final d = draft();
                final id = await phone.ledger.addExpense(d);
                expenses.add(id);
                await pumpEventQueue();
                _expectShows(phone, id, d, what);
              case 3 || 4 when expenses.isNotEmpty:
                what = 'edit';
                final id = expenses[r.nextInt(expenses.length)];
                final d = draft();
                await phone.ledger.updateExpense(id, d);
                await pumpEventQueue();
                _expectShows(phone, id, d, what);
              case 5 when expenses.isNotEmpty:
                what = 'delete';
                final id = expenses[r.nextInt(expenses.length)];
                await phone.ledger.deleteExpense(id);
                await pumpEventQueue();
                expect(
                  phone.state.expense(id)!.isDeleted,
                  isTrue,
                  reason: 'seed $seed step $step delete shows',
                );
              case 6 when expenses.isNotEmpty:
                what = 'restore';
                final id = expenses[r.nextInt(expenses.length)];
                if (phone.state.expense(id) == null) break;
                await phone.ledger.restoreExpense(id);
                await pumpEventQueue();
                expect(
                  phone.state.expense(id)!.isDeleted,
                  isFalse,
                  reason: 'seed $seed step $step restore shows',
                );
              case 7:
                what = 'pay';
                final from = ms[r.nextInt(ms.length)];
                final to = ms.firstWhere((m) => m != from);
                payments.add(
                  await phone.ledger.recordPayment(
                    _payment(g, from, to, total, currency: cur),
                  ),
                );
              case 8 when payments.isNotEmpty:
                what = 'updatePayment';
                final id = payments[r.nextInt(payments.length)];
                if (phone.state.expense(id) == null) break;
                final a = ms[r.nextInt(ms.length)];
                final b = ms[(ms.indexOf(a) + 1) % ms.length];
                await phone.ledger.updatePayment(
                  id,
                  _payment(g, a, b, total, currency: cur),
                );
                await pumpEventQueue();
                final m = phone.state.expense(id)!.money;
                expect(
                  [m.total, m.currency, m.paid, m.owed],
                  [
                    total,
                    cur,
                    {a: total},
                    {b: total},
                  ],
                  reason: 'seed $seed step $step updatePayment shows',
                );
              default:
                what = 'sync';
                await syncBoth(p, q, g);
            }
            commands++;
          } on LedgerException {
            // Random input may be refused (an expense not yet on this
            // phone, or deleted here); refusing is fine.
          }
          await pumpEventQueue();
          expectMoneyInvariants(phone, reason: 'seed $seed step $step $what');
        }
        // Clocks agree again, past every stamp written ahead.
        real += 9 * _day;
        for (final phone in [p, q]) {
          setClock(phone, kBaseMs + real);
        }
        await syncBoth(p, q, g);
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

  group('R39 split edges with the clock set back', () {
    test('1 minor unit over 3, maxMinor over 50, shares 1000:1, '
        'adjustment to rest 0', () async {
      final p = await QaPhone.create();
      addTearDown(p.dispose);
      final names = [for (var i = 1; i < 50; i++) 'M$i'];
      final t = await p.group(names);
      final g = t.g;
      final ms = t.m.values.toList()..sort();
      expect(ms.length, 50);
      p.tick(8 * _day);
      final e = await p.add(
        g,
        total: 1,
        paidBy: one(ms[49], 1),
        owedBy: eq(ms.take(3)),
      );
      p.tick(-8 * _day);
      expect(p.owed(e), {ms[0]: 1});

      for (final c in ['INR', 'JPY', 'KWD']) {
        await p.ledger.updateExpense(
          e,
          _draft(
            g,
            'max',
            Money.maxMinor,
            one(ms[0], Money.maxMinor),
            eq(ms),
            currency: c,
          ),
        );
        await pumpEventQueue();
        final owed = p.owed(e);
        expect(owed.values.fold(0, (a, b) => a + b), Money.maxMinor);
        // 99,999,999,999 / 50 = 1,999,999,999 r 49: the 49 lowest ids get
        // one more.
        for (var i = 0; i < 50; i++) {
          expect(
            owed[ms[i]],
            i < 49 ? 2000000000 : 1999999999,
            reason: '$c $i',
          );
        }
        expectMoneyInvariants(p, reason: c);
      }

      await p.ledger.updateExpense(
        e,
        _draft(
          g,
          'shares',
          1001,
          one(ms[0], 1001),
          spec(SplitMethod.shares, {ms[1]: 1000, ms[2]: 1}),
        ),
      );
      await pumpEventQueue();
      expect(p.owed(e), {ms[1]: 1000, ms[2]: 1});

      await p.ledger.updateExpense(
        e,
        _draft(
          g,
          'adj',
          900,
          one(ms[0], 900),
          spec(SplitMethod.adjustment, {ms[1]: 900, ms[2]: 0, ms[3]: 0}),
        ),
      );
      await pumpEventQueue();
      expect(p.owed(e), {ms[1]: 900});

      await p.ledger.updateExpense(
        e,
        _draft(
          g,
          'neg',
          900,
          one(ms[0], 900),
          spec(SplitMethod.adjustment, {ms[1]: -100, ms[2]: 0, ms[3]: 100}),
        ),
      );
      await pumpEventQueue();
      expect(p.owed(e), {ms[1]: 200, ms[2]: 300, ms[3]: 400});

      await p.ledger.updateExpense(
        e,
        _draft(
          g,
          'pct',
          100,
          one(ms[0], 100),
          spec(SplitMethod.percent, {ms[1]: 3333, ms[2]: 3333, ms[3]: 3334}),
        ),
      );
      await pumpEventQueue();
      expect(p.owed(e), {ms[1]: 33, ms[2]: 33, ms[3]: 34});
      expectMoneyInvariants(p, reason: 'edges');
    });
  });
}

void _expectShows(QaPhone p, ExpenseId id, ExpenseDraft d, String what) {
  final e = p.state.expense(id)!;
  expect(e.description, d.description, reason: '$what shows description');
  expect(e.money.total, d.total, reason: '$what shows total');
  expect(e.money.currency, d.currency, reason: '$what shows currency');
}

ExpenseDraft _draft(
  GroupId g,
  String description,
  int total,
  SplitSpec paidBy,
  SplitSpec owedBy, {
  String currency = 'INR',
}) => ExpenseDraft(
  groupId: g,
  description: description,
  total: total,
  currency: currency,
  paidBy: paidBy,
  owedBy: owedBy,
  category: 'general',
  date: utcFromMillis(kBaseMs),
);

PaymentDraft _payment(
  GroupId g,
  MemberId from,
  MemberId to,
  int amount, {
  String currency = 'INR',
}) => PaymentDraft(
  groupId: g,
  from: from,
  to: to,
  amount: amount,
  currency: currency,
  method: PaymentMethod.cash,
  date: utcFromMillis(kBaseMs),
);
