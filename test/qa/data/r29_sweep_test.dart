// QA DATA round 29: final regression sweep probes.
//
// The clock this phone restores at open (kv `hlc.last` merged with its
// newest own op) never goes backwards, which is the charter. This sweep
// looks at what that means once this phone's own wall clock was wrong
// for a while: a phone set more than Ledger.maxRemoteAheadMs (7 days)
// ahead writes an edit, the clock is corrected, and the HLC stayed ahead
// of it, so every later op was stamped further ahead than peers accept
// (DATA-R29-01, fixed: later ops are stamped from the corrected clock).
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:sqlite3/sqlite3.dart';
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

  /// B joins the trip and receives everything A holds now.
  Future<void> join() async {
    await b.ledger.registerJoinedGroup(
      t.g,
      (await a.ledger.groupKeys())[t.g]!,
      'Goa trip',
    );
    final r = await sync(a.ledger, b.ledger);
    expect(r.$1.outcome, SyncOutcome.completed, reason: r.$1.message);
    expect(b.opsOf(t.g).length, a.opsOf(t.g).length);
    expect(a.snap.totalUnshared, 0);
  }

  /// A's wall clock runs [aheadDays] ahead for one edit, then is corrected.
  Future<ExpenseId> wrongClockEdit(int aheadDays) async {
    a.clock.now = kQaBaseMs + aheadDays * _day;
    final e = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi, wrong date'),
    );
    a.clock.now = kQaBaseMs + 60 * 1000;
    return e;
  }

  test('a phone whose clock ran 30 days ahead for one edit: after the clock '
      'is corrected and the app restarted, the restored HLC is never behind '
      'its own ops, later ops are stamped from the corrected clock, and '
      'sync sessions complete (DATA-R29-01)', () async {
    await join();
    final taxi = await wrongClockEdit(30);
    final dinner = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Dinner'),
    );
    await a.restart();
    // The charter: the restored clock never goes behind this phone's ops.
    final restored = Hlc.parse((await a.sqlite.getKv(KvKeys.hlcLast))!);
    final newestOwn = a.mineIn(t.g).map((o) => o.hlc).reduce(
          (x, y) => x > y ? x : y,
        );
    expect(newestOwn.millis, greaterThanOrEqualTo(kQaBaseMs + 30 * _day));
    expect(restored.millis, lessThanOrEqualTo(a.clock.now + 3600 * 1000),
        reason: 'the corrected clock was saved after Dinner');
    final dinnerHlc = a.mineIn(t.g).last.hlc;
    expect(dinnerHlc.millis, lessThanOrEqualTo(a.clock.now),
        reason: 'Dinner is stamped from the corrected clock');
    // A sees it cannot share the Taxi yet.
    expect(a.ledger.clockSkewDetected, isTrue);
    final lunch = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.priya], description: 'Lunch'),
    );
    expect(a.mineIn(t.g).last.hlc > dinnerHlc, isTrue);
    final counters = [for (final o in a.mineIn(t.g)) o.counter];
    expect(counters, List.generate(counters.length, (i) => i + 1));
    expect(
      a.snap.state.expense(dinner)!.createdAt.millisecondsSinceEpoch,
      lessThanOrEqualTo(a.clock.now),
    );

    final r = await sync(a.ledger, b.ledger);
    expect(r.$1.outcome, SyncOutcome.completed, reason: r.$1.message);
    expect(r.$2.outcome, SyncOutcome.completed, reason: r.$2.message);
    expect(b.snap.state.expense(dinner), isNotNull);
    expect(b.snap.state.expense(lunch), isNotNull);
    expect(b.snap.state.expense(taxi), isNull,
        reason: 'the op stamped 30 days ahead is still held back');
    expect(b.ledger.clockSkewDetected, isTrue);
    // The data both phones hold is still intact across restarts.
    await b.restart();
    await a.restart();
    expect(a.snap.state.expense(lunch), isNotNull);
    expect(a.snap.state.expense(dinner), isNotNull);
    expect(a.snap.state.expense(taxi), isNotNull);
    expect(b.snap.state.expense(lunch), isNotNull);
    expect(b.snap.state.expense(dinner), isNotNull);

    // Once real time reaches the Taxi's stamp it is shared like any op,
    // and A no longer flags its clock.
    a.clock.now = kQaBaseMs + 30 * _day;
    b.clock.now = kQaBaseMs + 30 * _day;
    expect(a.ledger.clockSkewDetected, isFalse);
    await sync(a.ledger, b.ledger);
    expect(b.snap.state.expense(taxi), isNotNull);
    expect(a.snap.totalUnshared, 0);
  });

  test(
    'QA DATA-R29-01 repro: changes made after a wrongly-ahead clock is '
    'corrected reach a peer with the right clock',
    () async {
      await join();
      await wrongClockEdit(30);
      final dinner = await a.ledger.addExpense(
        qaDraft(t.g, [t.me, t.sam], description: 'Dinner'),
      );
      await a.restart();
      final lunch = await a.ledger.addExpense(
        qaDraft(t.g, [t.me, t.priya], description: 'Lunch'),
      );
      await sync(a.ledger, b.ledger);
      expect(
        b.snap.state.expense(dinner),
        isNotNull,
        reason: 'a change made with the right clock is shared',
      );
      expect(
        b.snap.state.expense(lunch),
        isNotNull,
        reason: 'a change made with the right clock after a restart is shared',
      );
    },
  );

  test(
    'QA DATA-R29-01 repro (variant): one flipped bit in the leading digit '
    'of a stored hlc.last does not stop later changes reaching a peer',
    () async {
      await join();
      await a.close();
      final db = sqlite3.open(a.path);
      try {
        final row = db.select('SELECT value FROM kv WHERE key = ?', [
          KvKeys.hlcLast,
        ]);
        final v = row.single.columnAt(0) as String;
        // '0' (0x30) -> '8' (0x38): still a well-formed HLC.
        db.execute('UPDATE kv SET value = ? WHERE key = ?', [
          '8${v.substring(1)}',
          KvKeys.hlcLast,
        ]);
      } finally {
        db.close();
      }
      await a.launch();
      final lunch = await a.ledger.addExpense(
        qaDraft(t.g, [t.me, t.priya], description: 'Lunch'),
      );
      await sync(a.ledger, b.ledger);
      expect(b.snap.state.expense(lunch), isNotNull);
    },
  );

  test('within the 7-day window the same story syncs (control)', () async {
    await join();
    await wrongClockEdit(6);
    await a.restart();
    final lunch = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.priya], description: 'Lunch'),
    );
    final r = await sync(a.ledger, b.ledger);
    expect(r.$1.outcome, SyncOutcome.completed, reason: r.$1.message);
    expect(b.snap.state.expense(lunch), isNotNull);
    expect(a.snap.totalUnshared, 0);
  });
}
