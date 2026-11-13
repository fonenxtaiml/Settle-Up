// QA DATA round 31: reverification sweep around the DATA-R29-01 fix (own
// ops are stamped from the corrected wall clock once the HLC ran more than
// OpFactory.maxLeadMs ahead) and the DATA-R29-02 fix (Settings reads
// LedgerSnapshot.clockSkewDetected).
//
// The class probed here: after this phone's clock ran far ahead for one
// edit, every kind of later change (not only addExpense) reaches a peer;
// restarts keep counters contiguous and stamps unique; and while this phone
// still holds an op peers hold back, it says so where the user can see it.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/sync/protocol/session.dart';

import '../../sync/support/harness.dart';
import 'qa_data_harness.dart';

const int _day = 24 * 60 * 60 * 1000;

void main() {
  late FilePhone a;
  late FilePhone b;
  late Trip t;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir());
    b = FilePhone(qaTempDir(), seed: 2);
    await a.launch();
    await b.launch();
    await a.settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
    await b.settings.completeOnboarding(
      displayName: 'Priya',
      homeCurrency: 'INR',
    );
    t = await qaTrip(a);
  });

  tearDown(() async {
    for (final p in [a, b]) {
      try {
        await p.close();
      } catch (_) {}
      p.dir.deleteSync(recursive: true);
    }
  });

  Future<(SessionResult, SessionResult)> sync(
    SyncStore initiator,
    SyncStore responder,
  ) async {
    final (ci, cr) = await channelPair();
    final r = await Future.wait([
      SyncSession(
        channel: ci,
        store: initiator,
        role: SessionRole.initiator,
        timings: fastTimings,
      ).run(),
      SyncSession(
        channel: cr,
        store: responder,
        role: SessionRole.responder,
        timings: fastTimings,
      ).run(),
    ]);
    return (r[0], r[1]);
  }

  Future<void> join() async {
    await b.ledger.registerJoinedGroup(
      t.g,
      (await a.ledger.groupKeys())[t.g]!,
      'Goa trip',
    );
    final r = await sync(a.ledger, b.ledger);
    expect(r.$1.outcome, SyncOutcome.completed, reason: r.$1.message);
    expect(a.snap.totalUnshared, 0);
  }

  Future<ExpenseId> wrongClockEdit(int aheadDays) async {
    a.clock.now = kQaBaseMs + aheadDays * _day;
    final e = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi, wrong date'),
    );
    a.clock.now = kQaBaseMs + 60 * 1000;
    return e;
  }

  void expectStampsUniqueAndSorted(FilePhone p) {
    final ops = p.snap.ops;
    final seen = <Hlc>{};
    for (var i = 0; i < ops.length; i++) {
      expect(
        seen.add(ops[i].hlc),
        isTrue,
        reason: 'stamp ${ops[i].hlc} used twice',
      );
      if (i > 0) {
        expect(
          ops[i - 1].hlc.compareTo(ops[i].hlc),
          lessThanOrEqualTo(0),
          reason: 'snapshot ops stay in HLC order',
        );
      }
    }
  }

  test('every kind of change made after the clock is corrected reaches the '
      'peer (rename group, add member, payment, edit and delete of an older '
      'expense, restore), across a restart; only the edit of the far-ahead '
      'op waits with it', () async {
    final older = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Hotel'),
    );
    final doomed = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.priya], description: 'Snacks'),
    );
    await join();
    final taxi = await wrongClockEdit(30);

    await a.ledger.updateGroup(t.g, const GroupPatch(name: 'Goa 2026'));
    final ravi = await a.ledger.addMember(t.g, displayName: 'Ravi');
    await a.restart();
    final pay = await a.ledger.recordPayment(
      PaymentDraft(
        groupId: t.g,
        from: t.sam,
        to: t.me,
        amount: 1500,
        currency: 'INR',
        method: PaymentMethod.upi,
        date: utcFromMillis(kQaBaseMs),
      ),
    );
    await a.ledger.updateExpense(
      older,
      qaDraft(t.g, [t.me, t.sam], description: 'Hotel, 2 nights'),
    );
    await a.ledger.deleteExpense(doomed);
    await a.ledger.restoreExpense(doomed);
    await a.ledger.deleteExpense(doomed);
    // Editing the expense written while the clock was wrong follows it
    // (it must beat that op on this phone).
    await a.ledger.updateExpense(
      taxi,
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi, fixed'),
    );
    expect(a.snap.state.expense(taxi)!.description, 'Taxi, fixed');

    final now = a.clock.now;
    for (final op in a.mineIn(t.g)) {
      final ahead = op.hlc.millis - now;
      final onTaxi = op.entityId == taxi;
      expect(
        ahead > 7 * _day,
        onTaxi,
        reason:
            'op ${op.counter} (${op.entityType.name}) is '
            '${ahead ~/ _day} days ahead',
      );
    }
    final counters = [for (final o in a.mineIn(t.g)) o.counter];
    expect(counters, List.generate(counters.length, (i) => i + 1));
    expectStampsUniqueAndSorted(a);

    final r = await sync(a.ledger, b.ledger);
    expect(r.$1.outcome, SyncOutcome.completed, reason: r.$1.message);
    expect(r.$2.outcome, SyncOutcome.completed, reason: r.$2.message);
    final bg = b.group(t.g);
    expect(bg.group!.name, 'Goa 2026');
    expect(bg.members[ravi]?.displayName, 'Ravi');
    expect(b.snap.state.expense(pay), isNotNull);
    expect(b.snap.state.expense(older)!.description, 'Hotel, 2 nights');
    expect(b.snap.state.expense(doomed)!.isDeleted, isTrue);
    expect(b.snap.state.expense(taxi), isNull);

    // Both phones agree on everything but the held-back Taxi.
    await a.restart();
    await b.restart();
    expectStampsUniqueAndSorted(a);
    expectStampsUniqueAndSorted(b);
    expect(a.group(t.g).group!.name, 'Goa 2026');
    expect(a.snap.state.expense(taxi)!.description, 'Taxi, fixed');

    // Once real time reaches the Taxi, it and its edit are shared.
    a.clock.now = kQaBaseMs + 31 * _day;
    b.clock.now = kQaBaseMs + 31 * _day;
    await sync(a.ledger, b.ledger);
    expect(b.snap.state.expense(taxi)!.description, 'Taxi, fixed');
    expect(a.snap.totalUnshared, 0);
    expect(a.ledger.clockSkewDetected, isFalse);
  });

  test('a group created while the clock ran 30 days ahead: later changes '
      'in it are stamped from the corrected clock (printed: what a joining '
      'peer sees)', () async {
    a.clock.now = kQaBaseMs + 30 * _day;
    final g = await a.ledger.createGroup(
      const NewGroup(
        name: 'Far trip',
        type: GroupType.trip,
        currency: 'INR',
        newMemberNames: ['Sam'],
      ),
    );
    a.clock.now = kQaBaseMs + 60 * 1000;
    final me = a
        .group(g)
        .members
        .values
        .firstWhere((m) => m.displayName == 'Alex')
        .id;
    final sam = a
        .group(g)
        .members
        .values
        .firstWhere((m) => m.displayName == 'Sam')
        .id;
    final e = await a.ledger.addExpense(qaDraft(g, [me, sam]));
    expect(a.snap.state.expense(e), isNotNull);
    final last = a.mineIn(g).last.hlc.millis;
    expect(last, lessThanOrEqualTo(a.clock.now));
    await b.ledger.registerJoinedGroup(
      g,
      (await a.ledger.groupKeys())[g]!,
      'Far trip',
    );
    final r = await sync(a.ledger, b.ledger);
    expect(r.$1.outcome, SyncOutcome.completed, reason: r.$1.message);
    expect(
      a.ledger.clockSkewDetected,
      isTrue,
      reason: 'A holds the group create, which peers hold back',
    );
    final bSees = b.snap.state.groups[g]?.group != null;
    // ignore: avoid_print
    print(
      '[r31] far group: B sees group $bSees, pending join '
      '${b.snap.pendingJoins.containsKey(g)}; A '
      'unshared ${a.snap.unsharedCounts[g]}; A snapshot flag '
      '${a.snap.clockSkewDetected}',
    );
  });

  test(
    'the clock saved after a set-back is restored and set back again: '
    'counters stay contiguous and no stamp repeats over several restarts',
    () async {
      await join();
      await wrongClockEdit(40);
      for (var i = 0; i < 4; i++) {
        await a.ledger.addExpense(
          qaDraft(t.g, [t.me, t.sam], description: 'Round $i'),
        );
        await a.restart();
        final kv = Hlc.parse((await a.sqlite.getKv(KvKeys.hlcLast))!);
        expect(kv.millis, lessThanOrEqualTo(a.clock.now + 3600 * 1000));
        a.clock.now += 1000;
      }
      final counters = [for (final o in a.mineIn(t.g)) o.counter];
      expect(counters, List.generate(counters.length, (i) => i + 1));
      expectStampsUniqueAndSorted(a);
      await sync(a.ledger, b.ledger);
      for (var i = 0; i < 4; i++) {
        expect(
          b.group(t.g).expenses.values.any((x) => x.description == 'Round $i'),
          isTrue,
        );
      }
    },
  );

  test(
    'QA DATA-R31-01 repro: while this phone holds its own op that peers '
    'hold back, the snapshot Settings reads carries the clock flag',
    () async {
      await join();
      await wrongClockEdit(30);
      await a.restart();
      final dinner = await a.ledger.addExpense(
        qaDraft(t.g, [t.me, t.sam], description: 'Dinner'),
      );
      await sync(a.ledger, b.ledger);
      expect(b.snap.state.expense(dinner), isNotNull);
      // The ledger knows it cannot share the Taxi yet ...
      expect(a.ledger.clockSkewDetected, isTrue);
      // ... and A still shows the Taxi and the delivered Dinner as not
      // shared, so Settings must explain why. Settings reads
      // ledgerProvider (LedgerSnapshot.clockSkewDetected).
      expect(a.snap.totalUnshared, greaterThan(0));
      expect(a.snap.clockSkewDetected, a.ledger.clockSkewDetected);
    },
  );
}
