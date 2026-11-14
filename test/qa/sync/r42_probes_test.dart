// QA SYNC round 42: reverification of SYNC-R41-01 ("sent N changes" counts
// what the sync shared, not every ACKed batch) across the defect class:
// interrupted sessions at every drop point, several groups in one session,
// a relaying third phone behind a held-back gap, and repeated syncs.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
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

  Future<void> recorded(QaPhone p, int before) async {
    expect(
      await waitFor(() async => (await p.records()).length > before),
      isTrue,
    );
  }

  /// Syncs [from] with [to]; returns the records written by each side.
  Future<(SyncRecord, SyncRecord)> sync(QaPhone from, QaPhone to) async {
    final fromBefore = (await from.records()).length;
    final toBefore = (await to.records()).length;
    await syncByLink(from, to);
    await recorded(to, toBefore);
    expect((await from.records()).length, fromBefore + 1);
    return ((await from.records()).first, (await to.records()).first);
  }

  /// A's own ops that B's version vector covers.
  Future<int> coveredOf(QaPhone a, QaPhone b, GroupId g) async =>
      (await b.ledger.versionVector(g))[a.deviceId];

  group('SYNC-R41-01 class', () {
    // 200 of A's own ops over 16 KiB BLE frames: several batches, 4-batch
    // window. For every drop point A's "sent" never exceeds what B is
    // newly known to hold, never exceeds the drop in A's badge, and once
    // the next session completes nothing is counted twice.
    for (final drop in [5, 6, 7, 8, 9, 10, 12, 15, 20]) {
      test(
        'drop after $drop frames: sent bounded by what B came to hold',
        () async {
          final a = await phone('a', "Alex's Pixel");
          final b = await phone('b', "Priya's Pixel");
          final s = await a.seedGroup(expenses: 0);
          await b.join(a, s.g);
          await sync(b, a);
          await a.addExpenses(s, 200);
          final badge0 = unshared(a, s.g);
          final covered0 = await coveredOf(a, b, s.g);

          a.ble.dropAfterFrames = drop;
          a.lan.failConnect = true;
          final bBefore = (await b.records()).length;
          final aBefore = (await a.records()).length;
          await b.engine.startHosting();
          final peer = await a.find(b, transports: 2);
          try {
            await a.engine.syncWith(peer);
          } on SyncException catch (_) {}
          await recorded(a, aBefore);
          await recorded(b, bBefore);
          final ra = (await a.records()).first;
          final rb = (await b.records()).first;
          final covered1 = await coveredOf(a, b, s.g);
          final badge1 = unshared(a, s.g);
          expect(
            ra.sentOps,
            lessThanOrEqualTo(covered1 - covered0),
            reason: 'drop $drop: sent more than B came to hold',
          );
          expect(
            ra.sentOps,
            lessThanOrEqualTo(badge0 - badge1),
            reason: 'drop $drop: sent more than the badge fell',
          );
          expect(rb.receivedOps, covered1 - covered0, reason: 'drop $drop');
          if (ra.outcome != SyncOutcome.completed) {
            expect(
              ra.outcome,
              ra.sentOps > 0 || ra.receivedOps > 0
                  ? SyncOutcome.partial
                  : SyncOutcome.failed,
            );
          }

          a.ble.dropAfterFrames = null;
          a.lan.failConnect = false;
          await waitFor(() => b.engine.status.session is! SessionActive);
          final badge2 = unshared(a, s.g);
          final (ra2, rb2) = await sync(a, b);
          expect(ra2.outcome, SyncOutcome.completed);
          expect(
            ra2.sentOps,
            lessThanOrEqualTo(badge2),
            reason: 'drop $drop: resume counted an op twice',
          );
          expect(ra.sentOps + ra2.sentOps, lessThanOrEqualTo(200));
          expect(rb.receivedOps + rb2.receivedOps, 200);
          expect(unshared(a, s.g), 0);
          expect(b.canonical, a.canonical);
          // A further sync is idempotent and claims nothing.
          final (ra3, rb3) = await sync(a, b);
          expect(ra3.sentOps, 0);
          expect(rb3.receivedOps, 0);
        },
      );
    }

    test('two groups in one session: the held-back group counts 0, the '
        'other counts what it shared', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final g1 = await a.seedGroup(expenses: 1);
      final g2 = await a.seedGroup(expenses: 1, name: 'Flat');
      await b.join(a, g1.g);
      await b.join(a, g2.g);
      await sync(b, a);
      expect(unshared(a, g1.g) + unshared(a, g2.g), 0);
      a.clock.offset = _day * 10;
      await a.addExpense(g1.g, payer: g1.a, owers: [g1.a, g1.b]);
      a.clock.offset = Duration.zero;
      await a.addExpense(g1.g, payer: g1.a, owers: [g1.a, g1.b]);
      await a.addExpenses(g2, 3);
      for (var i = 0; i < 3; i++) {
        final (rb, ra) = await sync(b, a);
        expect(ra.sentOps, i == 0 ? 3 : 0, reason: 'sync $i');
        expect(rb.receivedOps, i == 0 ? 4 : 0, reason: 'sync $i');
        expect(unshared(a, g1.g), 2);
        expect(unshared(a, g2.g), 0);
      }
    });

    test('a relay behind the held-back gap claims nothing either', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final c = await phone('c', "Sam's Galaxy");
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      await c.join(a, s.g);
      await sync(b, a);
      await sync(c, a);
      // A's clock 10 days ahead for X; C's too, so C accepts X.
      a.clock.offset = _day * 10;
      c.clock.offset = _day * 10;
      await a.addExpense(s.g, payer: s.a, owers: [s.a, s.b], description: 'X');
      a.clock.offset = Duration.zero;
      await a.addExpense(s.g, payer: s.a, owers: [s.a, s.b], description: 'Y');
      final (rc, _) = await sync(c, a);
      expect(rc.receivedOps, 2);
      c.clock.offset = Duration.zero;
      await c.ledger.recheckClock();
      for (var i = 0; i < 3; i++) {
        final (rb, rcHost) = await sync(b, c);
        expect(rb.receivedOps, i == 0 ? 1 : 0, reason: 'B stores Y once');
        expect(rcHost.sentOps, 0, reason: 'C relays X and Y, sync $i');
      }
    });
  });
}
