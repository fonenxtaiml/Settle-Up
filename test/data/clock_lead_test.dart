// DATA-R29-01: an own clock that ran ahead must not hold back every later
// change. A plain local op is never stamped more than OpFactory.maxLeadMs
// ahead of the wall clock; an edit of an entity whose newest op is stamped
// far ahead (by this phone, or by a peer on top of this phone's stamp,
// MONEY-R39-01) still follows it, so the edit takes effect locally.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/op_factory.dart';
import 'package:settle_up/data/repositories.dart';
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

  test('a wall clock set back up to the lead keeps the clock monotonic; '
      'past it, later ops are stamped from the wall clock and reach a peer '
      'whose clock is 2 days behind', () async {
    await join();
    a.clock.now = kQaBaseMs + 4 * _day;
    final x = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
    a.clock.now = kQaBaseMs + 60000;
    final y = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
    expect(
      newestOpOf(a, y).hlc > newestOpOf(a, x).hlc,
      isTrue,
      reason: 'within the lead the clock never goes backwards',
    );

    a.clock.now = kQaBaseMs + 12 * _day;
    final z = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
    a.clock.now = kQaBaseMs + 120000;
    await a.restart();
    final w = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
    expect(
      newestOpOf(a, w).hlc.millis,
      lessThanOrEqualTo(a.clock.now + OpFactory.maxLeadMs),
    );
    expect(newestOpOf(a, w).hlc > newestOpOf(a, y).hlc, isTrue);
    b.clock.now = kQaBaseMs - 2 * _day;
    expect(await sync(), SyncOutcome.completed);
    expect(b.snap.state.expense(w), isNotNull);
    expect(b.snap.state.expense(z), isNull);
    expect(a.ledger.clockSkewDetected, isTrue);
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

  // MONEY-R39-01: the far-ahead newest op of an entity may be a peer's
  // edit made on top of this phone's own far-ahead stamp (the peer adopted
  // it). Every kind of local write on such an entity still takes effect
  // here and reaches the peer.
  test('a peer edit on top of this phone\'s stamp from a week ahead: every '
      'later edit, delete, restore and rename here still wins', () async {
    await join();
    final e = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi'),
    );
    expect(await sync(), SyncOutcome.completed);
    a.clock.now = kQaBaseMs + 15 * _day ~/ 2;
    b.clock.now = kQaBaseMs + _day;
    await a.ledger.updateExpense(
      e,
      qaDraft(t.g, [t.me, t.sam], description: 'A ahead'),
    );
    await a.ledger.renameMember(t.g, t.priya, 'Priya (A ahead)');
    await a.ledger.updateGroup(t.g, const GroupPatch(name: 'Goa (A ahead)'));
    expect(await sync(), SyncOutcome.completed);
    b.clock.advance(1000);
    await b.ledger.updateExpense(
      e,
      qaDraft(t.g, [t.me, t.sam], description: 'B on top'),
    );
    await b.ledger.renameMember(t.g, t.priya, 'Priya (B)');
    await b.ledger.updateGroup(t.g, const GroupPatch(name: 'Goa (B)'));
    expect(await sync(), SyncOutcome.completed);
    expect(a.snap.state.expense(e)!.description, 'B on top');
    expect(newestOpOf(a, e).deviceId, b.deviceId);

    // A's date is corrected: B's stamps are now more than 7 days ahead.
    a.clock.now = kQaBaseMs + 60000;
    final floor = newestOpOf(a, e).hlc;
    expect(floor.millis, greaterThan(a.clock.now + HlcClock.maxAdoptDriftMs));
    await a.ledger.updateExpense(
      e,
      qaDraft(t.g, [t.me, t.sam], description: 'A fixed'),
    );
    expect(a.snap.state.expense(e)!.description, 'A fixed');
    expect(newestOpOf(a, e).hlc > floor, isTrue);
    await a.ledger.renameMember(t.g, t.priya, 'Priya (A fixed)');
    expect(a.group(t.g).members[t.priya]!.displayName, 'Priya (A fixed)');
    await a.ledger.updateGroup(t.g, const GroupPatch(name: 'Goa (A fixed)'));
    expect(a.group(t.g).group!.name, 'Goa (A fixed)');
    await a.restart();
    await a.ledger.deleteExpense(e);
    expect(a.group(t.g).liveExpenses.map((x) => x.id), isNot(contains(e)));
    await a.ledger.restoreExpense(e);
    expect(a.group(t.g).liveExpenses.map((x) => x.id), contains(e));
    // A new expense is still stamped from the corrected clock.
    final lunch = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Lunch'),
    );
    expect(
      newestOpOf(a, lunch).hlc.millis,
      lessThanOrEqualTo(a.clock.now + OpFactory.maxLeadMs),
    );
    final own = a.snap.ops.where((o) => o.deviceId == a.deviceId).toList();
    expect(own.map((o) => o.hlc).toSet().length, own.length);

    // B (1 day ahead) accepts the edits: they are stamped after his own.
    expect(await sync(), SyncOutcome.completed);
    expect(b.snap.state.expense(e)!.description, 'A fixed');
    expect(b.group(t.g).members[t.priya]!.displayName, 'Priya (A fixed)');
    expect(b.group(t.g).group!.name, 'Goa (A fixed)');
    expect(b.snap.state.expense(lunch), isNotNull);
    expect(b.snap.state.toCanonicalJson(), a.snap.state.toCanonicalJson());
  });

  // Property over two phones whose dates jump days ahead and back
  // independently, editing the same entities and syncing in between:
  // what a phone just saved is what it shows, whoever wrote the entity's
  // newest op and however far ahead (MONEY-R39-01), own stamps stay
  // unique, and once real time passes every stamp both converge.
  for (var seed = 1; seed <= 10; seed++) {
    test(
      'two-phone clock story $seed: a local write always wins locally',
      () async {
        final rnd = Random(4000 + seed);
        await join();
        final phones = [a, b];
        final expenses = <ExpenseId>[];
        var real = 0;
        final offset = {a: 0, b: 0};
        const offsets = [
          0,
          0,
          _day,
          -_day,
          3 * _day,
          6 * _day,
          8 * _day,
          15 * _day ~/ 2,
          12 * _day,
          30 * _day,
        ];
        for (var step = 0; step < 40; step++) {
          real += 1000 + rnd.nextInt(60000);
          final p = phones[rnd.nextInt(2)];
          if (rnd.nextInt(4) == 0) {
            offset[p] = offsets[rnd.nextInt(offsets.length)];
          }
          for (final q in phones) {
            q.clock.now = kQaBaseMs + real + offset[q]!;
          }
          final r = rnd.nextInt(10);
          final why = 'seed $seed step $step';
          // The expenses this phone holds (a peer's may not have reached it).
          final held = [
            for (final e in expenses)
              if (p.snap.state.expense(e) != null) e,
          ];
          if (r <= 1 || held.isEmpty) {
            final d = 'E$step';
            final e = await p.ledger.addExpense(
              qaDraft(t.g, [t.me, t.sam], description: d),
            );
            expenses.add(e);
            expect(p.snap.state.expense(e)!.description, d, reason: why);
          } else if (r <= 4) {
            final e = held[rnd.nextInt(held.length)];
            final before = newestOpOf(p, e).hlc;
            final d = 'E$step edit';
            await p.ledger.updateExpense(
              e,
              qaDraft(t.g, [t.me, t.sam], description: d),
            );
            expect(p.snap.state.expense(e)!.description, d, reason: why);
            expect(newestOpOf(p, e).hlc > before, isTrue, reason: why);
          } else if (r == 5) {
            final e = held[rnd.nextInt(held.length)];
            final deleted = p.snap.state.expense(e)!.isDeleted;
            if (deleted) {
              await p.ledger.restoreExpense(e);
            } else {
              await p.ledger.deleteExpense(e);
            }
            expect(p.snap.state.expense(e)!.isDeleted, !deleted, reason: why);
          } else if (r == 6) {
            final n = 'Sam $step';
            await p.ledger.renameMember(t.g, t.sam, n);
            expect(p.group(t.g).members[t.sam]!.displayName, n, reason: why);
          } else if (r == 7) {
            await p.restart();
          } else {
            expect(await sync(), SyncOutcome.completed, reason: why);
          }
        }
        for (final p in phones) {
          final own = p.snap.ops.where((o) => o.deviceId == p.deviceId);
          expect(
            own.map((o) => o.hlc).toSet().length,
            own.length,
            reason: 'seed $seed: no two own ops share a stamp',
          );
        }
        a.clock.now = kQaBaseMs + 80 * _day;
        b.clock.now = a.clock.now;
        expect(await sync(), SyncOutcome.completed);
        expect(await sync(), SyncOutcome.completed);
        expect(a.snap.totalUnshared, 0, reason: 'seed $seed');
        expect(
          b.snap.state.toCanonicalJson(),
          a.snap.state.toCanonicalJson(),
          reason: 'seed $seed',
        );
      },
    );
  }

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
