// Regression for QA SYNC-R41-01: "sent N changes" counts what the sync
// shared with the peer (offered ops its ACK version vector came to cover),
// not the size of every ACKed batch. Held-back ops and the ops re-sent
// behind them are ACKed every sync until the gap closes, and the unshared
// badge reads the same version vector, so the two must move together.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

const _day = Duration(days: 1);

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(String letter, String name) async {
    final p = await QaPhone.create(hub, letter, name);
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

  int unshared(QaPhone p, GroupId g) => p.snapshot.unsharedCounts[g] ?? 0;

  /// Syncs [from] with [to] and returns the record each side wrote.
  Future<(SyncRecord, SyncRecord)> sync(QaPhone from, QaPhone to) async {
    final fromBefore = (await from.records()).length;
    final toBefore = (await to.records()).length;
    await syncByLink(from, to);
    expect(
      await waitFor(() async => (await to.records()).length > toBefore),
      isTrue,
    );
    expect((await from.records()).length, fromBefore + 1);
    return ((await from.records()).first, (await to.records()).first);
  }

  test(
    'fresh pair: sent is every op the peer stored, both directions',
    () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final s = await a.seedGroup(expenses: 3);
      await b.join(a, s.g);
      final ops = a.opCount(s.g);
      expect(unshared(a, s.g), ops);
      final (rb, ra) = await sync(b, a);
      expect(ra.sentOps, ops);
      expect(rb.receivedOps, ops);
      expect(rb.sentOps, 0);
      expect(unshared(a, s.g), 0);

      await b.addExpense(s.g, payer: s.b, owers: [s.a, s.b]);
      final (ra2, rb2) = await sync(a, b);
      expect(rb2.sentOps, 1, reason: 'B hosts and sends');
      expect(ra2.receivedOps, 1);
      expect(ra2.sentOps, 0);
      expect(unshared(b, s.g), 0);
    },
  );

  test('held-back gap: sent 0 on either side while the badge stays, then '
      'sent 2 when the gap closes and the badge clears', () async {
    final a = await phone('a', "Alex's Pixel");
    final b = await phone('b', "Priya's Pixel");
    final s = await a.seedGroup(expenses: 1);
    await b.join(a, s.g);
    await sync(b, a);
    a.clock.offset = _day * 10;
    await a.addExpense(s.g, payer: s.a, owers: [s.a, s.b], description: 'X');
    a.clock.offset = Duration.zero;
    await a.addExpense(s.g, payer: s.a, owers: [s.a, s.b], description: 'Y');

    // B stores Y but not X: its VV still stops before X, so nothing is
    // known shared yet and A will offer both again.
    final (rb, ra) = await sync(b, a);
    expect(rb.receivedOps, 1);
    expect(ra.sentOps, 0);
    expect(unshared(a, s.g), 2);

    // A dials this time (A is the initiator that sends).
    for (var i = 0; i < 2; i++) {
      final (ra2, rb2) = await sync(a, b);
      expect(ra2.sentOps, 0, reason: 'A dials, repeat $i');
      expect(rb2.receivedOps, 0);
      final (rb3, ra3) = await sync(b, a);
      expect(ra3.sentOps, 0, reason: 'B dials, repeat $i');
      expect(rb3.receivedOps, 0);
      expect(unshared(a, s.g), 2);
    }
    // Every one of those syncs completed and claimed nothing.
    for (final r in (await a.records()).take(5)) {
      expect(r.outcome, SyncOutcome.completed);
      expect(r.sentOps, 0);
    }

    a.clock.offset += _day * 10;
    b.clock.offset += _day * 10;
    await a.ledger.recheckClock();
    final (rb4, ra4) = await sync(b, a);
    expect(rb4.receivedOps, 1, reason: 'X stored');
    expect(ra4.sentOps, 2, reason: 'X and Y now covered by B');
    expect(unshared(a, s.g), 0);
    expect(b.canonical, a.canonical);
    final (rb5, ra5) = await sync(b, a);
    expect(ra5.sentOps, 0);
    expect(rb5.receivedOps, 0);
  });

  test('a relay counts the third phone\'s ops it shares', () async {
    final a = await phone('a', "Alex's Pixel");
    final b = await phone('b', "Priya's Pixel");
    final c = await phone('c', "Sam's Galaxy");
    final s = await a.seedGroup(expenses: 2);
    await b.join(a, s.g);
    await c.join(a, s.g);
    await sync(b, a);
    final ops = b.opCount(s.g);
    final (rc, rb) = await sync(c, b);
    expect(rb.sentOps, ops, reason: "B relays A's ops to C");
    expect(rc.receivedOps, ops);
    final (rc2, ra) = await sync(c, a);
    expect(ra.sentOps, 0, reason: 'C already holds them');
    expect(rc2.receivedOps, 0);
  });

  // Seeded property: one author (A) adds ops, some stamped 8-12 days
  // ahead (past the 7 days B accepts, so B holds them back);
  // syncs run in random directions while real time moves on. After every
  // sync, A's "sent" equals how far its unshared badge fell, never more
  // than the ops B is newly known to hold, and B's "got" is what it stored.
  for (final seed in [1, 7, 23, 101, 4242]) {
    test(
      'property (seed $seed): sent equals the drop in the unshared badge',
      () async {
        final rnd = Random(seed);
        final a = await phone('a', "Alex's Pixel");
        final b = await phone('b', "Priya's Pixel");
        final s = await a.seedGroup(expenses: 0);
        await b.join(a, s.g);
        await sync(b, a);
        var now = Duration.zero;
        var sentTotal = 0;
        var gotTotal = 0;
        for (var step = 0; step < 14; step++) {
          final adds = rnd.nextInt(3);
          for (var i = 0; i < adds; i++) {
            final ahead = rnd.nextInt(4) == 0;
            a.clock.offset =
                now + (ahead ? _day * (8 + rnd.nextInt(5)) : Duration.zero);
            await a.addExpense(
              s.g,
              payer: s.a,
              owers: [s.a, s.b],
              total: 100 + step * 10 + i,
              description: 'S$step-$i',
            );
            a.clock.offset = now;
          }
          if (rnd.nextInt(3) == 0) {
            now += _day * (1 + rnd.nextInt(3));
            a.clock.offset = now;
            b.clock.offset = now;
            await a.ledger.recheckClock();
            await b.ledger.recheckClock();
          }
          final before = unshared(a, s.g);
          final heldBefore = b.opCount(s.g);
          final aDials = rnd.nextBool();
          final SyncRecord ra;
          final SyncRecord rb;
          if (aDials) {
            (ra, rb) = await sync(a, b);
          } else {
            (rb, ra) = await sync(b, a);
          }
          final after = unshared(a, s.g);
          expect(ra.outcome, SyncOutcome.completed);
          expect(ra.sentOps, before - after, reason: 'seed $seed step $step');
          expect(ra.sentOps, greaterThanOrEqualTo(0));
          expect(rb.receivedOps, b.opCount(s.g) - heldBefore);
          expect(rb.sentOps, 0, reason: 'B authored nothing');
          sentTotal += ra.sentOps;
          gotTotal += rb.receivedOps;
        }
        // Once time passes every stamp, everything is shared and the totals
        // agree: each op counted sent once and got once.
        now += _day * 10;
        a.clock.offset = now;
        b.clock.offset = now;
        await a.ledger.recheckClock();
        await b.ledger.recheckClock();
        final before = unshared(a, s.g);
        final heldBefore = b.opCount(s.g);
        final (rb, ra) = await sync(b, a);
        expect(ra.sentOps, before);
        sentTotal += ra.sentOps;
        gotTotal += rb.receivedOps;
        expect(rb.receivedOps, b.opCount(s.g) - heldBefore);
        expect(unshared(a, s.g), 0);
        expect(b.canonical, a.canonical);
        expect(sentTotal, gotTotal, reason: 'seed $seed');
      },
    );
  }
}
