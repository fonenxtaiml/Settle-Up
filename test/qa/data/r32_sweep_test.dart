// QA DATA round 32: reverification sweep around the DATA-R31-01 fix (the
// snapshot Settings reads carries LedgerSnapshot.clockNotice, the same value
// as Ledger.clockSkewDetected, and the ledger re-checks it as the wall clock
// moves).
//
// The class probed here: every path that changes what the notice depends on
// (a local command, a failed command, a sync that delivers or holds back,
// time passing, a restart) leaves the published snapshot equal to the
// getter, on the SQLite store the app uses, and the notice says the right
// reason.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/protocol/session.dart';

import '../../sync/support/harness.dart';
import 'qa_data_harness.dart';

const int _hour = 60 * 60 * 1000;
const int _day = 24 * _hour;

void main() {
  late FilePhone a;
  late FilePhone b;
  late FaultyStore faulty;
  late Trip t;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir())..wrap = (s) => faulty = FaultyStore(s);
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

  void expectSame(FilePhone p, String when) {
    expect(
      p.snap.clockSkewDetected,
      p.ledger.clockSkewDetected,
      reason:
          '$when: snapshot ${p.snap.clockNotice} vs getter '
          '${p.ledger.clockSkewDetected}',
    );
  }

  test('own change 30 days ahead on the SQLite store: the notice holds '
      'through restarts, clears once the date is near, and the change is '
      'then shared', () async {
    await join();
    a.clock.now = kQaBaseMs + 30 * _day;
    final taxi = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi, wrong date'),
    );
    final taxiMs = a.snap.ops.last.hlc.millis;
    a.clock.now = kQaBaseMs + 60 * 1000;
    await a.restart();
    expect(a.snap.clockNotice, ClockNotice.ownChangesAhead);
    expectSame(a, 'after restart');
    final dinner = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Dinner'),
    );
    await sync(a.ledger, b.ledger);
    expect(b.snap.state.expense(dinner), isNotNull);
    expect(b.snap.state.expense(taxi), isNull, reason: 'B holds it back');
    expect(a.snap.clockNotice, ClockNotice.ownChangesAhead);
    expectSame(a, 'after sync');
    final unsharedBefore = a.snap.unsharedCounts[t.g];
    await a.restart();
    expect(a.snap.unsharedCounts[t.g], unsharedBefore);
    expectSame(a, 'second restart');

    // Real time reaches the Taxi's date less 7 days: both clocks move.
    final near = taxiMs - Ledger.maxRemoteAheadMs + _hour;
    a.clock.now = near;
    b.clock.now = near;
    await a.ledger.recheckClock();
    expect(a.snap.clockNotice, ClockNotice.none);
    expectSame(a, 'date near');
    final r = await sync(a.ledger, b.ledger);
    expect(r.$1.outcome, SyncOutcome.completed, reason: r.$1.message);
    expect(b.snap.state.expense(taxi), isNotNull);
    expect(a.snap.totalUnshared, 0);
    await a.restart();
    expect(a.snap.clockNotice, ClockNotice.none);
    expect(a.snap.totalUnshared, 0);
    expectSame(a, 'third restart');
  });

  test('an own stamp up to 7 days ahead (peers accept it) gives no notice '
      'on this phone when it is edited later; the peer that received it '
      'says a synced phone was ahead', () async {
    await join();
    a.clock.now = kQaBaseMs + 3 * _day;
    final e = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Hotel'),
    );
    a.clock.now = kQaBaseMs + 60 * 1000;
    await a.restart();
    await a.ledger.updateExpense(
      e,
      qaDraft(t.g, [t.me, t.sam], description: 'Hotel, 2 nights'),
    );
    expect(a.snap.state.expense(e)!.description, 'Hotel, 2 nights');
    expect(a.snap.clockNotice, ClockNotice.none);
    expectSame(a, 'A after own edit');
    b.clock.now = kQaBaseMs + 60 * 1000;
    await sync(a.ledger, b.ledger);
    expect(b.snap.state.expense(e)!.description, 'Hotel, 2 nights');
    expect(b.snap.clockNotice, ClockNotice.peerAhead);
    expectSame(b, 'B after sync');
    expect(a.snap.totalUnshared, 0);
  });

  test(
    'QA DATA-R32-01 repro: a command that fails to store leaves the '
    'snapshot notice equal to the getter',
    () async {
      await join();
      // B's clock runs 2 days ahead when it adds an expense A then syncs.
      b.clock.now = kQaBaseMs + 2 * _day;
      final x = await b.ledger.addExpense(
        qaDraft(t.g, [t.me, t.sam], description: 'Boat'),
      );
      await sync(b.ledger, a.ledger);
      expect(a.snap.state.expense(x), isNotNull);
      expect(a.snap.clockNotice, ClockNotice.peerAhead);
      expectSame(a, 'after receive');
      // After a restart the skew guard has not fired yet; editing B's
      // expense stamps after B's stamp (tickAfter), which sets it.
      await a.restart();
      final noticeAtOpen = a.snap.clockNotice;
      faulty.failNextInsert = true;
      await expectLater(
        a.ledger.updateExpense(
          x,
          qaDraft(t.g, [t.me, t.sam], description: 'Boat ride'),
        ),
        throwsA(isA<LedgerException>()),
      );
      // ignore: avoid_print
      print(
        '[r32] failed edit: notice at open $noticeAtOpen, snapshot '
        '${a.snap.clockNotice}, getter ${a.ledger.clockSkewDetected}',
      );
      expectSame(a, 'after failed edit');
      await a.ledger.updateExpense(
        x,
        qaDraft(t.g, [t.me, t.sam], description: 'Boat ride'),
      );
      expectSame(a, 'after next edit');
    },
  );

  test('recheckClock racing close and commands never throws and never '
      'publishes after close', () async {
    a.clock.now = kQaBaseMs + 30 * _day;
    await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
    a.clock.now = kQaBaseMs;
    final seen = <ClockNotice>[];
    final sub = a.ledger.watch().listen((s) => seen.add(s.clockNotice));
    final futures = <Future<void>>[
      a.ledger.recheckClock(),
      a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam], description: 'Tea')),
      a.ledger.recheckClock(),
    ];
    await Future.wait(futures);
    expect(seen.last, ClockNotice.ownChangesAhead);
    expectSame(a, 'after race');
    final closing = a.ledger.close();
    final afterClose = a.ledger.recheckClock();
    await Future.wait([closing, afterClose]);
    await a.ledger.recheckClock();
    await sub.cancel();
    await a.launch();
    expect(a.snap.clockNotice, ClockNotice.ownChangesAhead);
  });

  test('a group deleted while it holds own changes far ahead (printed: '
      'whether the notice stays while Home shows nothing unshared)', () async {
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
    await a.ledger.deleteGroup(g);
    expectSame(a, 'after delete');
    final GroupId other = t.g;
    // ignore: avoid_print
    print(
      '[r32] deleted far group: notice ${a.snap.clockNotice}, unshared '
      '${a.snap.unsharedCounts}, other group unshared '
      '${a.snap.unsharedCounts[other]}',
    );
  });
}
