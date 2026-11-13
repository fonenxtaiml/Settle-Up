// DATA-R32-01: a command that fails changes nothing the clock notice reads,
// and the published snapshot always carries the getter's value (SPEC 7.3).
//
// The class: any command path that throws after stamping or after the wall
// clock moved. A failing command whose notice changed publishes it before
// the error reaches the caller; one whose notice did not publishes nothing.
// The clock's last stamp is never set back, so own stamps stay unique even
// when a write landed but reported failure.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/protocol/session.dart';

import '../qa/data/qa_data_harness.dart';
import '../sync/support/harness.dart';

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

  Future<void> sync(SyncStore initiator, SyncStore responder) async {
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
    expect(r[0].outcome, SyncOutcome.completed, reason: r[0].message);
  }

  Future<void> join() async {
    await b.ledger.registerJoinedGroup(
      t.g,
      (await a.ledger.groupKeys())[t.g]!,
      'Goa trip',
    );
    await sync(a.ledger, b.ledger);
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

  /// B adds an expense while its clock runs [ahead] of A's, then syncs it
  /// to A, and A restarts (the skew flag is not persisted).
  Future<ExpenseId> peerAheadExpense({int ahead = 2 * _day}) async {
    await join();
    b.clock.now = kQaBaseMs + ahead;
    final x = await b.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Boat'),
    );
    await sync(b.ledger, a.ledger);
    expect(a.snap.clockNotice, ClockNotice.peerAhead);
    await a.restart();
    expect(a.snap.clockNotice, ClockNotice.none);
    return x;
  }

  test('a refused edit of a peer-ahead entity publishes the flag it set, '
      'once, and stores nothing', () async {
    final x = await peerAheadExpense();
    final seen = <ClockNotice>[];
    final sub = a.ledger.watch().skip(1).listen((s) => seen.add(s.clockNotice));
    final before = a.snap;
    faulty.failNextInsert = true;
    await expectLater(
      a.ledger.updateExpense(x, qaDraft(t.g, [t.me, t.sam], description: 'B2')),
      throwsA(
        isA<LedgerException>().having(
          (e) => e.code,
          'code',
          LedgerErrorCode.storageFailed,
        ),
      ),
    );
    await pumpEventQueue();
    expect(a.ledger.clockSkewDetected, isTrue);
    expect(a.snap.clockNotice, ClockNotice.peerAhead);
    expect(seen, [ClockNotice.peerAhead]);
    expect(a.snap.ops.length, before.ops.length, reason: 'nothing stored');
    expect(a.snap.state.toCanonicalJson(), before.state.toCanonicalJson());
    expect(a.snap.unsharedOpIds, before.unsharedOpIds);
    await a.ledger.updateExpense(
      x,
      qaDraft(t.g, [t.me, t.sam], description: 'Boat ride'),
    );
    expectSame(a, 'after the next edit');
    expect(a.snap.state.expense(x)!.description, 'Boat ride');
    await sub.cancel();
  });

  test('a refused write that changes no notice publishes nothing', () async {
    final seen = <ClockNotice>[];
    final sub = a.ledger.watch().skip(1).listen((s) => seen.add(s.clockNotice));
    faulty.failNextInsert = true;
    await expectLater(
      a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam], description: 'Tea')),
      throwsA(isA<LedgerException>()),
    );
    await expectLater(
      a.ledger.updateGroup('no-such-group', const GroupPatch(name: 'X')),
      throwsA(isA<LedgerException>()),
    );
    await pumpEventQueue();
    expect(seen, isEmpty);
    expectSame(a, 'after the failures');
    await sub.cancel();
  });

  test('a refused edit while the flag is already set keeps it', () async {
    final x = await peerAheadExpense();
    await a.ledger.updateExpense(
      x,
      qaDraft(t.g, [t.me, t.sam], description: 'Boat ride'),
    );
    expect(a.snap.clockNotice, ClockNotice.peerAhead);
    faulty.failNextInsert = true;
    await expectLater(
      a.ledger.updateExpense(x, qaDraft(t.g, [t.me, t.sam], description: 'B3')),
      throwsA(isA<LedgerException>()),
    );
    expect(a.ledger.clockSkewDetected, isTrue);
    expect(a.snap.clockNotice, ClockNotice.peerAhead);
  });

  test('a write that landed but reported failure keeps own stamps unique: '
      'the clock is not set back', () async {
    final x = await peerAheadExpense();
    faulty.failAfterNextInsert = true;
    await expectLater(
      a.ledger.updateExpense(x, qaDraft(t.g, [t.me, t.sam], description: 'B4')),
      throwsA(isA<LedgerException>()),
    );
    expectSame(a, 'after the lost reply');
    // Several further commands at the same wall-clock instant.
    for (var i = 0; i < 4; i++) {
      try {
        await a.ledger.updateExpense(
          x,
          qaDraft(t.g, [t.me, t.sam], description: 'Boat $i'),
        );
      } on LedgerException catch (e) {
        // The first one may reuse the counter the lost write took.
        expect(e.code, LedgerErrorCode.storageFailed);
      }
      expectSame(a, 'after command $i');
    }
    await a.restart();
    final mine = [
      for (final op in a.snap.ops)
        if (op.deviceId == a.deviceId) op.hlc,
    ];
    expect(mine.toSet().length, mine.length, reason: 'own stamps unique');
    expect(a.snap.state.expense(x)!.description, 'Boat 3');
  });

  test('a failing command after the wall clock moved publishes the notice '
      'it changed before throwing', () async {
    a.clock.now = kQaBaseMs + 30 * _day;
    await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam], description: 'Far'));
    a.clock.now = kQaBaseMs;
    await a.ledger.recheckClock();
    expect(a.snap.clockNotice, ClockNotice.ownChangesAhead);
    // The date comes near; nothing has re-checked yet.
    a.clock.now = kQaBaseMs + 30 * _day;
    expect(a.ledger.clockSkewDetected, isFalse);
    expect(a.snap.clockNotice, ClockNotice.ownChangesAhead);
    final seen = <ClockNotice>[];
    final sub = a.ledger.watch().skip(1).listen((s) => seen.add(s.clockNotice));
    await expectLater(
      a.ledger.updateGroup('no-such-group', const GroupPatch(name: 'X')),
      throwsA(isA<LedgerException>()),
    );
    await pumpEventQueue();
    expect(seen, [ClockNotice.none]);
    expectSame(a, 'after the failed command');
    await sub.cancel();
  });

  test('property: seeded random peer-ahead syncs, edits, store failures, '
      'restarts and clock moves never leave the snapshot notice apart from '
      'the getter', () async {
    await join();
    final rnd = Random(3201);
    final expenses = <ExpenseId>[];
    var bAhead = 0;
    var aMoved = 0;
    var failedPeerAheadEdits = 0;
    for (var step = 0; step < 120; step++) {
      final r = rnd.nextInt(12);
      if (r == 0) {
        // The getter follows the wall clock at once; the snapshot follows
        // on the next command or re-check (the app re-checks on resume).
        aMoved += rnd.nextInt(3) * _day;
        a.clock.now = kQaBaseMs + aMoved;
        if (rnd.nextBool()) {
          await a.ledger.recheckClock();
          expectSame(a, 'step $step (re-check)');
        }
        continue;
      } else if (r == 1) {
        await a.restart();
      } else if (r <= 4) {
        // B's clock runs ahead by up to 3 days more each time, staying
        // within the 7 days A accepts.
        bAhead = min(
          bAhead + rnd.nextInt(4) * _day + rnd.nextInt(3) * _hour,
          aMoved + 6 * _day,
        );
        b.clock.now = kQaBaseMs + bAhead;
        expenses.add(
          await b.ledger.addExpense(
            qaDraft(t.g, [t.me, t.sam], description: 'B $step'),
          ),
        );
        await sync(b.ledger, a.ledger);
      } else {
        final fault = rnd.nextInt(3);
        if (fault == 0) faulty.failNextInsert = true;
        if (fault == 1) faulty.failAfterNextInsert = true;
        final skewBefore = a.snap.clockNotice;
        try {
          if (expenses.isNotEmpty && rnd.nextInt(4) != 0) {
            final x = expenses[rnd.nextInt(expenses.length)];
            if (a.snap.state.expense(x) == null) continue;
            await a.ledger.updateExpense(
              x,
              qaDraft(t.g, [t.me, t.sam], description: 'A $step'),
            );
          } else {
            expenses.add(
              await a.ledger.addExpense(
                qaDraft(t.g, [t.me, t.sam], description: 'A new $step'),
              ),
            );
          }
        } on LedgerException {
          // Expected for an injected fault.
          if (skewBefore != a.snap.clockNotice) failedPeerAheadEdits++;
        }
        faulty
          ..failNextInsert = false
          ..failAfterNextInsert = false;
      }
      expectSame(a, 'step $step (r $r)');
    }
    // The class this guards was hit, not only the easy paths.
    expect(failedPeerAheadEdits, greaterThan(0));
  });
}
