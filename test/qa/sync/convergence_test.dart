// QA SYNC-R1: concurrent offline edits, gossip, rings, clock skew and
// repeated syncs, through the real DefaultSyncEngine and Ledger.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(
    String letter,
    String name, {
    SkewedClock? clock,
    bool sqlite = false,
  }) async {
    final p = await QaPhone.create(
      hub,
      letter,
      name,
      clock: clock,
      sqlite: sqlite,
    );
    phones.add(p);
    return p;
  }

  setUp(() => hub = MemoryTransportHub());
  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
  });

  /// Alex owns a group with [n] expenses; Priya has synced it once.
  Future<(QaPhone, QaPhone, QaSeed, List<ExpenseId>)> pair({
    int n = 3,
    SkewedClock? alexClock,
    SkewedClock? priyaClock,
    bool sqlite = false,
  }) async {
    final alex = await phone(
      'a',
      "Alex's Pixel",
      clock: alexClock,
      sqlite: sqlite,
    );
    final priya = await phone(
      'b',
      "Priya's Pixel",
      clock: priyaClock,
      sqlite: sqlite,
    );
    final seed = await alex.seedGroup(expenses: n);
    await priya.join(alex, seed.g);
    await syncByLink(priya, alex);
    expect(priya.canonical, alex.canonical);
    final ids = alex.state.groups[seed.g]!.expenses.keys.toList()..sort();
    return (alex, priya, seed, ids);
  }

  group('concurrent offline edits converge', () {
    for (final sqlite in [false, true]) {
      final store = sqlite ? 'sqlite' : 'memory';
      test('same field on both phones ($store)', () async {
        final (alex, priya, _, ids) = await pair(sqlite: sqlite);
        await alex.edit(ids[0], description: 'Dinner (Alex)');
        await priya.edit(ids[0], description: 'Dinner (Priya)');
        await syncByLink(alex, priya);
        expect(alex.canonical, priya.canonical);
        final winner = alex.state.expense(ids[0])!.description;
        expect(winner, anyOf('Dinner (Alex)', 'Dinner (Priya)'));
        // The later HLC wins (Priya wrote second on a shared wall clock).
        expect(winner, 'Dinner (Priya)');
      });

      test(
        'different fields on both phones keep both edits ($store)',
        () async {
          final (alex, priya, _, ids) = await pair(sqlite: sqlite);
          await alex.edit(ids[1], description: 'Taxi to airport');
          await priya.edit(ids[1], total: 4321);
          await syncByLink(priya, alex);
          expect(alex.canonical, priya.canonical);
          final x = alex.state.expense(ids[1])!;
          expect(x.description, 'Taxi to airport');
          expect(x.money.total, 4321);
        },
      );

      test('edit on one phone, delete on the other ($store)', () async {
        final (alex, priya, _, ids) = await pair(sqlite: sqlite);
        await alex.edit(ids[2], description: 'Edited while deleted');
        await priya.ledger.deleteExpense(ids[2]);
        await syncByLink(alex, priya);
        expect(alex.canonical, priya.canonical);
        expect(alex.state.expense(ids[2])!.isDeleted, isTrue);
      });

      test('both phones add "Bob" offline ($store)', () async {
        final (alex, priya, seed, _) = await pair(sqlite: sqlite);
        final b1 = await alex.ledger.addMember(seed.g, displayName: 'Bob');
        final b2 = await priya.ledger.addMember(seed.g, displayName: 'Bob');
        await syncByLink(alex, priya);
        expect(alex.canonical, priya.canonical);
        final bobs = alex.state.groups[seed.g]!.members.values
            .where((m) => m.displayName == 'Bob' && !m.isRemoved)
            .map((m) => m.id)
            .toSet();
        expect(bobs, {b1, b2});
        // Merging the duplicates on one phone converges too.
        await alex.ledger.mergeMembers(seed.g, from: b2, into: b1);
        await syncByLink(priya, alex);
        expect(alex.canonical, priya.canonical);
      });
    }

    test('both phones edit, delete and restore in a burst', () async {
      final (alex, priya, seed, ids) = await pair(n: 6);
      for (var i = 0; i < 6; i++) {
        if (i.isEven) {
          await alex.edit(ids[i], total: 2000 + i);
          await priya.ledger.deleteExpense(ids[i]);
        } else {
          await priya.edit(ids[i], description: 'P$i');
          await alex.ledger.deleteExpense(ids[i]);
          await alex.ledger.restoreExpense(ids[i]);
        }
      }
      await alex.addExpenses(seed, 4);
      await priya.addExpenses(seed, 4, base: 900);
      await syncByLink(alex, priya);
      expect(alex.canonical, priya.canonical);
      expect(alex.opCount(seed.g), priya.opCount(seed.g));
    });
  });

  group('gossip', () {
    test('A and C converge through B without meeting', () async {
      final a = await phone('a', 'A');
      final b = await phone('b', 'B');
      final c = await phone('c', 'C');
      final s = await a.seedGroup(expenses: 2);
      await b.join(a, s.g);
      await c.join(a, s.g);
      await a.addExpenses(s, 5);
      await syncByLink(b, a); // A <-> B
      await c.addExpenses(s, 0); // nothing yet: C only has the key
      await syncByLink(c, b); // B <-> C: C gets A's ops via B
      expect(c.canonical, a.canonical);
      // C writes; it reaches A through B.
      await c.addExpense(
        s.g,
        payer: s.a,
        owers: [s.a, s.b],
        description: 'From C',
      );
      await syncByLink(b, c);
      await syncByLink(a, b);
      expect(a.canonical, c.canonical);
      expect(allEqual([a, b, c]), isTrue);
    });

    test('ring A<->B, B<->C, C<->A with writes everywhere reaches a fixed '
        'point', () async {
      final a = await phone('a', 'A');
      final b = await phone('b', 'B');
      final c = await phone('c', 'C');
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      await c.join(a, s.g);
      await syncByLink(b, a);
      await syncByLink(c, b);
      for (var round = 0; round < 3; round++) {
        await a.addExpenses(s, 3, base: 100 + 100 * round);
        await b.addExpenses(s, 2, base: 1000 + 100 * round);
        await c.addExpenses(s, 1, base: 5000 + 100 * round);
        final ids = a.state.groups[s.g]!.expenses.keys.toList()..sort();
        await b.edit(ids.first, description: 'B round $round');
        await syncByLink(a, b);
        await syncByLink(b, c);
        await syncByLink(c, a);
      }
      // One more lap with nothing to do changes nothing on anyone.
      await syncByLink(a, b);
      final fixed = a.canonical.toString();
      final count = a.totalOps;
      final lap = [
        await syncByLink(a, b),
        await syncByLink(b, c),
        await syncByLink(c, a),
      ];
      for (final s in lap) {
        expect(s.sentOps + s.receivedOps, 0);
      }
      expect(allEqual([a, b, c]), isTrue);
      expect(a.canonical.toString(), fixed);
      expect(a.totalOps, count);
      expect(b.totalOps, count);
      expect(c.totalOps, count);
    });
  });

  group('clock skew', () {
    for (final (label, skew) in [
      ('+2 h', const Duration(hours: 2)),
      ('-1 day', const Duration(days: -1)),
    ]) {
      test(
        'Priya $label: convergence, skewDetected, deterministic winner',
        () async {
          final (alex, priya, _, ids) = await pair(
            priyaClock: SkewedClock(skew),
          );
          // Concurrent edits of one field; Alex writes LAST in real time.
          await priya.edit(ids[0], description: 'Priya');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await alex.edit(ids[0], description: 'Alex');
          await syncByLink(alex, priya);
          expect(alex.canonical, priya.canonical);
          final w = alex.state.expense(ids[0])!.description;
          // LWW by HLC: the phone whose clock is ahead wins.
          expect(w, skew.isNegative ? 'Alex' : 'Priya');
          // The phone that saw a clock > 1 h ahead of its own flags it.
          if (skew.isNegative) {
            expect(priya.ledger.clockSkewDetected, isTrue);
            expect(alex.ledger.clockSkewDetected, isFalse);
          } else {
            expect(alex.ledger.clockSkewDetected, isTrue);
            expect(priya.ledger.clockSkewDetected, isFalse);
          }
          // Syncing again in the other direction does not flip the winner.
          await syncByLink(priya, alex);
          expect(alex.state.expense(ids[0])!.description, w);
          expect(priya.state.expense(ids[0])!.description, w);
        },
      );
    }
  });

  group('repeated syncs are idempotent', () {
    test(
      '5 syncs: op count and snapshot unchanged, a record per sync',
      () async {
        final (alex, priya, seed, _) = await pair(n: 20);
        await alex.addExpenses(seed, 7);
        await priya.addExpenses(seed, 3, base: 700);
        await syncByLink(alex, priya);
        final canonical = alex.canonical.toString();
        final ops = alex.totalOps;
        final aRecords = (await alex.records()).length;
        final pRecords = (await priya.records()).length;
        for (var i = 0; i < 5; i++) {
          final s = i.isEven
              ? await syncByLink(alex, priya)
              : await syncByLink(priya, alex);
          expect(s.sentOps, 0);
          expect(s.receivedOps, 0);
          expect(s.receivedByGroup.values.fold(0, (a, b) => a + b), 0);
        }
        expect(alex.canonical.toString(), canonical);
        expect(priya.canonical.toString(), canonical);
        expect(alex.totalOps, ops);
        expect(priya.totalOps, ops);
        await waitFor(
          () async => (await priya.records()).length == pRecords + 5,
        );
        expect((await alex.records()).length, aRecords + 5);
        expect((await priya.records()).length, pRecords + 5);
        for (final r in (await alex.records()).take(5)) {
          expect(r.outcome, SyncOutcome.completed);
        }
        expect(alex.snapshot.unsharedCounts, isEmpty);
        expect(priya.snapshot.unsharedCounts, isEmpty);
      },
    );

    test('a sync with nothing shared in common to send records 0/0', () async {
      final (alex, priya, _, _) = await pair(n: 0);
      final s = await syncByLink(alex, priya);
      expect((s.sentOps, s.receivedOps), (0, 0));
      expect(alex.canonical, priya.canonical);
    });
  });

  test('balances agree after convergence (not just canonical JSON)', () async {
    final (alex, priya, seed, ids) = await pair(n: 5);
    await alex.edit(ids[0], total: 999);
    await priya.edit(ids[0], total: 1001);
    await priya.ledger.recordPayment(
      PaymentDraft(
        groupId: seed.g,
        from: seed.b,
        to: seed.a,
        amount: 500,
        currency: 'INR',
        method: PaymentMethod.cash,
        date: utcFromMillis(kBaseMs),
      ),
    );
    await syncByLink(alex, priya);
    expect(alex.canonical, priya.canonical);
    final ga = alex.state.groups[seed.g]!;
    final gp = priya.state.groups[seed.g]!;
    expect(ga.expenses.length, gp.expenses.length);
    expect(
      ga.expenses.values.map((e) => e.money.total).toList()..sort(),
      gp.expenses.values.map((e) => e.money.total).toList()..sort(),
    );
  });
}
