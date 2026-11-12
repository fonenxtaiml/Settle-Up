// QA DATA round 29: final regression sweep probes.
//
// The clock this phone restores at open (kv `hlc.last` merged with its
// newest own op) never goes backwards, which is the charter. This sweep
// looks at what that means once this phone's own wall clock was wrong
// for a while: a phone set more than Ledger.maxRemoteAheadMs (7 days)
// ahead writes an edit, the clock is corrected, and the HLC stays ahead
// of it, so every later op is stamped further ahead than peers accept.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
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
      'its own ops and sync sessions still complete (what reaches the peer '
      'is printed; DATA-R29-01 holds the expectation)', () async {
    await join();
    await wrongClockEdit(30);
    final dinner = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Dinner'),
    );
    await a.restart();
    // The charter: the restored clock never goes backwards.
    final last = a.mineIn(t.g).last.hlc;
    expect(last.millis, greaterThanOrEqualTo(kQaBaseMs + 30 * _day));
    final lunch = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.priya], description: 'Lunch'),
    );
    expect(a.mineIn(t.g).last.hlc > last, isTrue);
    final counters = [for (final o in a.mineIn(t.g)) o.counter];
    expect(counters, List.generate(counters.length, (i) => i + 1));

    final r = await sync(a.ledger, b.ledger);
    expect(r.$1.outcome, SyncOutcome.completed, reason: r.$1.message);
    expect(r.$2.outcome, SyncOutcome.completed, reason: r.$2.message);
    // ignore: avoid_print
    print(
      '[r29] 30 days ahead once: A stamps now +'
      '${(a.mineIn(t.g).last.hlc.millis - a.clock.now) ~/ _day} days; '
      'after sync B holds dinner: ${b.snap.state.expense(dinner) != null}, '
      'lunch: ${b.snap.state.expense(lunch) != null}; A unshared '
      '${a.snap.totalUnshared}; skew flag A ${a.ledger.clockSkewDetected}, '
      'B ${b.ledger.clockSkewDetected}',
    );
    // The data both phones hold is still intact across restarts.
    await b.restart();
    await a.restart();
    expect(a.snap.state.expense(lunch), isNotNull);
    expect(a.snap.state.expense(dinner), isNotNull);
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
    skip:
        'QA DATA-R29-01: after this phone\'s clock ran more than 7 days '
        'ahead for one edit, every later change it makes is held back '
        'by peers until real time catches up, with no sign on this phone',
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
