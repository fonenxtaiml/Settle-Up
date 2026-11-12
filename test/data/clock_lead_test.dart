// DATA-R29-01: an own clock that ran ahead must not hold back every later
// change. A plain local op is never stamped more than OpFactory.maxLeadMs
// ahead of the wall clock; an edit of an entity whose newest op this phone
// stamped far ahead still follows it, so the edit takes effect locally.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/op_factory.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:sqlite3/sqlite3.dart';

import '../qa/data/qa_data_harness.dart';
import '../sync/support/harness.dart';

const int _day = 24 * 60 * 60 * 1000;
const int _hour = 60 * 60 * 1000;

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

  Future<SyncOutcome> sync() async {
    final (ci, cr) = await channelPair();
    final r = await Future.wait([
      SyncSession(
        channel: ci,
        store: a.ledger,
        role: SessionRole.initiator,
        timings: fastTimings,
      ).run(),
      SyncSession(
        channel: cr,
        store: b.ledger,
        role: SessionRole.responder,
        timings: fastTimings,
      ).run(),
    ]);
    return r[0].outcome;
  }

  Future<void> join() async {
    await b.ledger.registerJoinedGroup(
      t.g,
      (await a.ledger.groupKeys())[t.g]!,
      'Goa trip',
    );
    expect(await sync(), SyncOutcome.completed);
  }

  Operation newestOpOf(FilePhone p, String entityId) => p.snap.ops
      .where((o) => o.entityId == entityId)
      .reduce((x, y) => x.hlc > y.hlc ? x : y);

  test('an edit of an expense written while the clock ran ahead takes '
      'effect on this phone and is stamped after it', () async {
    a.clock.now = kQaBaseMs + 40 * _day;
    final taxi = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi'),
    );
    a.clock.now = kQaBaseMs + 60000;
    final before = newestOpOf(a, taxi).hlc;
    await a.ledger.updateExpense(
      taxi,
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi, fixed'),
    );
    expect(a.snap.state.expense(taxi)!.description, 'Taxi, fixed');
    expect(newestOpOf(a, taxi).hlc > before, isTrue);
    await a.restart();
    await a.ledger.deleteExpense(taxi);
    expect(a.group(t.g).liveExpenses.map((e) => e.id), isNot(contains(taxi)));
    await a.ledger.restoreExpense(taxi);
    expect(a.group(t.g).liveExpenses.map((e) => e.id), contains(taxi));
    // A new expense after all that is stamped from the corrected clock.
    final lunch = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Lunch'),
    );
    expect(
      newestOpOf(a, lunch).hlc.millis,
      lessThanOrEqualTo(a.clock.now + OpFactory.maxLeadMs),
    );
  });

  test('a clock corrected back mid-session: the next op is stamped from it '
      'and reaches a peer, and this phone flags its clock', () async {
    await join();
    a.clock.now = kQaBaseMs + 8 * _day;
    await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam], description: 'X'));
    expect(
      a.ledger.clockSkewDetected,
      isFalse,
      reason: 'nothing tells this phone its clock is wrong yet',
    );
    a.clock.now = kQaBaseMs + 60000;
    expect(
      a.ledger.clockSkewDetected,
      isTrue,
      reason: 'it holds an op peers will hold back',
    );
    final y = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Y'),
    );
    expect(await sync(), SyncOutcome.completed);
    expect(b.snap.state.expense(y), isNotNull);
  });

  test('after a peer stamp days ahead is adopted for an edit, the next new '
      'op is stamped from the wall clock again', () async {
    await join();
    b.clock.now = kQaBaseMs + 3 * _day;
    final e = await b.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
    expect(await sync(), SyncOutcome.completed);
    await a.ledger.updateExpense(
      e,
      qaDraft(t.g, [t.me, t.sam], description: 'Edited on A'),
    );
    expect(
      a.snap.state.expense(e)!.description,
      'Edited on A',
      reason: 'SYNC-R1-01 still holds',
    );
    final next = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
    expect(
      newestOpOf(a, next).hlc.millis,
      lessThanOrEqualTo(a.clock.now + OpFactory.maxLeadMs),
    );
  });

  test('any damaged leading digit of a stored hlc.last: the next change is '
      'stamped near the wall clock and reaches a peer', () async {
    await join();
    for (var digit = 1; digit <= 9; digit++) {
      await a.close();
      final db = sqlite3.open(a.path);
      try {
        final v =
            db
                    .select('SELECT value FROM kv WHERE key = ?', [
                      KvKeys.hlcLast,
                    ])
                    .single
                    .columnAt(0)
                as String;
        db.execute('UPDATE kv SET value = ? WHERE key = ?', [
          '$digit${v.substring(1)}',
          KvKeys.hlcLast,
        ]);
      } finally {
        db.close();
      }
      await a.launch();
      final e = await a.ledger.addExpense(
        qaDraft(t.g, [t.me, t.sam], description: 'After damage $digit'),
      );
      expect(
        newestOpOf(a, e).hlc.millis,
        lessThanOrEqualTo(a.clock.now + OpFactory.maxLeadMs),
        reason: 'digit $digit',
      );
      expect(await sync(), SyncOutcome.completed);
      expect(b.snap.state.expense(e), isNotNull, reason: 'digit $digit');
      expect(a.snap.totalUnshared, 0, reason: 'digit $digit');
      final saved = Hlc.parse((await a.sqlite.getKv(KvKeys.hlcLast))!);
      expect(
        saved.millis,
        lessThanOrEqualTo(a.clock.now + _hour),
        reason: 'the damaged value is replaced',
      );
      a.clock.advance(1000);
      b.clock.advance(1000);
    }
  });

  // Property: whatever the wall clock does (jumps days ahead, back, small
  // drift) and whatever the user does in between (adds, edits, deletes,
  // restarts), every own op has a unique stamp, every edit takes effect,
  // every op made while the clock is right and not on a far-ahead entity
  // is stamped within the lead and reaches a peer with the right clock,
  // and once real time passes every stamp both phones converge.
  for (var seed = 1; seed <= 12; seed++) {
    test('seeded clock story $seed', () async {
      final rnd = Random(seed);
      await join();
      final mine = <ExpenseId>[];
      final aheadEntities = <String>{};
      final shouldReach = <ExpenseId>{};
      final expected = <ExpenseId, String>{};
      var wrong = false;
      for (var step = 0; step < 30; step++) {
        final r = rnd.nextInt(10);
        if (r == 0) {
          // The wall clock jumps ahead by up to 60 days.
          a.clock.now = kQaBaseMs + step * 60000 + rnd.nextInt(60) * _day;
          wrong = a.clock.now > kQaBaseMs + step * 60000 + 7 * _day;
        } else if (r == 1) {
          a.clock.now = kQaBaseMs + step * 60000; // corrected
          wrong = false;
        } else if (r == 2) {
          await a.restart();
        } else if (r <= 5 || mine.isEmpty) {
          final d = 'E$step';
          final e = await a.ledger.addExpense(
            qaDraft(t.g, [t.me, t.sam], description: d),
          );
          mine.add(e);
          expected[e] = d;
          if (wrong) {
            aheadEntities.add(e);
          } else {
            shouldReach.add(e);
            expect(
              newestOpOf(a, e).hlc.millis,
              lessThanOrEqualTo(a.clock.now + OpFactory.maxLeadMs),
            );
          }
        } else {
          final e = mine[rnd.nextInt(mine.length)];
          final before = newestOpOf(a, e).hlc;
          final d = 'E$step edit';
          await a.ledger.updateExpense(
            e,
            qaDraft(t.g, [t.me, t.sam], description: d),
          );
          expected[e] = d;
          expect(newestOpOf(a, e).hlc > before, isTrue);
          if (wrong) {
            aheadEntities.add(e);
            shouldReach.remove(e);
          }
        }
        for (final e in mine) {
          expect(a.snap.state.expense(e)!.description, expected[e]);
        }
        if (!wrong) a.clock.now += 1000;
      }
      final own = a.snap.ops.where((o) => o.deviceId == a.deviceId).toList();
      expect(
        own.map((o) => o.hlc).toSet().length,
        own.length,
        reason: 'no two own ops share a stamp',
      );
      final counters = own.map((o) => o.counter).toList()..sort();
      expect(counters, List.generate(counters.length, (i) => i + 1));

      // B's clock is right: what was made with the right clock reaches it.
      a.clock.now = kQaBaseMs + 30 * 60000;
      b.clock.now = a.clock.now;
      expect(await sync(), SyncOutcome.completed);
      for (final e in shouldReach) {
        expect(
          b.snap.state.expense(e)?.description,
          expected[e],
          reason: 'seed $seed: $e',
        );
      }
      if (aheadEntities.isNotEmpty) expect(a.ledger.clockSkewDetected, isTrue);

      // Once real time passes every stamp, both phones converge.
      a.clock.now = kQaBaseMs + 70 * _day;
      b.clock.now = a.clock.now;
      expect(await sync(), SyncOutcome.completed);
      expect(a.snap.totalUnshared, 0);
      for (final e in mine) {
        expect(b.snap.state.expense(e)?.description, expected[e]);
      }
    });
  }
}
