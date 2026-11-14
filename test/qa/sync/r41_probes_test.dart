// QA SYNC round 41: reverification of SYNC-R39-01 ("got N changes" counted
// re-sent duplicates). The session result now reports the ops it stored
// (_storedOps) and keeps the wire count for progress only. These probes
// run the defect class through the real DefaultSyncEngine and Ledger: the
// responder side, a repeat sync that brings one new op among duplicates,
// two groups at once, a phone that met the gap only through gossip, a
// sync whose only incoming op is held back, an interrupted sync that
// carried only duplicates, and the gap closing once real time catches up.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

const _day = Duration(days: 1);

int _sum(Map<GroupId, int> m) => m.values.fold(0, (a, b) => a + b);

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(String letter, String name, {bool spy = false}) async {
    final p = await QaPhone.create(hub, letter, name, spyStore: spy);
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

  /// A (10 days ahead) adds X, comes back and adds Y; B syncs once and
  /// holds X back. Returns the seed.
  Future<QaSeed> gap(QaPhone a, QaPhone b) async {
    final s = await a.seedGroup(expenses: 1);
    await b.join(a, s.g);
    await syncByLink(b, a);
    a.clock.offset = _day * 10;
    await a.addExpense(s.g, payer: s.a, owers: [s.a, s.b], description: 'X');
    a.clock.offset = Duration.zero;
    await a.addExpense(s.g, payer: s.a, owers: [s.a, s.b], description: 'Y');
    final first = await syncByLink(b, a);
    expect(first.receivedOps, 1, reason: 'X held back, Y stored');
    expect(first.receivedByGroup[s.g], 1);
    return s;
  }

  group('SYNC-R39-01 class: got counts only ops stored', () {
    test('responder side: B hosts, A dials; B records got 0 on each '
        'repeat and A got 0', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final s = await gap(a, b);
      final held = b.opCount(s.g);
      for (var i = 0; i < 3; i++) {
        final before = (await b.records()).length;
        final r = await syncByLink(a, b);
        expect(r.receivedOps, 0);
        await waitFor(() async => (await b.records()).length > before);
        final rec = (await b.records()).first;
        expect(rec.outcome, SyncOutcome.completed);
        expect(rec.receivedOps, 0, reason: 'responder record');
        expect(b.opCount(s.g), held);
      }
    });

    test('one new op among re-sent duplicates: got 1 on the summary, the '
        'group line and the record', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel", spy: true);
      final s = await gap(a, b);
      await a.addExpense(s.g, payer: s.a, owers: [s.a, s.b], description: 'Z');
      final dups = b.spy.duplicatesIgnored;
      final r = await syncByLink(b, a);
      expect(
        b.spy.duplicatesIgnored,
        greaterThan(dups),
        reason: 'Y came again over the wire',
      );
      expect(r.receivedOps, 1);
      expect(r.receivedByGroup, {s.g: 1});
      expect((await b.records()).first.receivedOps, 1);
    });

    test('two groups, the gap in one and a new op in the other: got is the '
        'sum of the group lines', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final s = await gap(a, b);
      final f = await a.seedGroup(expenses: 0, name: 'Flat');
      await b.join(a, f.g);
      await syncByLink(b, a);
      await a.addExpense(
        f.g,
        payer: f.a,
        owers: [f.a, f.b],
        description: 'Rent',
      );
      await a.addExpense(
        f.g,
        payer: f.a,
        owers: [f.a, f.b],
        description: 'Wifi',
      );
      final r = await syncByLink(b, a);
      expect(r.receivedByGroup[s.g] ?? 0, 0);
      expect(r.receivedByGroup[f.g], 2);
      expect(r.receivedOps, 2);
      expect(r.receivedOps, _sum(r.receivedByGroup));
      expect((await b.records()).first.receivedOps, 2);
    });

    test('C meets the gap through gossip (B) and then A: got 0 when A '
        're-sends what C already holds', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final c = await phone('c', "Sam's Galaxy");
      final s = await gap(a, b);
      await c.join(a, s.g);
      final cb = await syncByLink(c, b);
      expect(cb.receivedOps, _sum(cb.receivedByGroup));
      final held = c.opCount(s.g);
      final ca = await syncByLink(c, a);
      expect(c.opCount(s.g), held);
      expect(ca.receivedOps, 0);
      expect(ca.receivedOps, _sum(ca.receivedByGroup));
      expect((await c.records()).first.receivedOps, 0);
    });

    test(
      'the only incoming op is held back: got 0, completed, skew set',
      () async {
        final a = await phone('a', "Alex's Pixel");
        final b = await phone('b', "Priya's Pixel");
        final s = await a.seedGroup(expenses: 1);
        await b.join(a, s.g);
        await syncByLink(b, a);
        a.clock.offset = _day * 10;
        await a.addExpense(
          s.g,
          payer: s.a,
          owers: [s.a, s.b],
          description: 'X',
        );
        a.clock.offset = Duration.zero;
        final r = await syncByLink(b, a);
        expect(r.receivedOps, 0);
        expect(r.receivedByGroup[s.g] ?? 0, 0);
        expect(b.ledger.clockSkewDetected, isTrue);
        final rec = (await b.records()).first;
        expect(rec.outcome, SyncOutcome.completed);
        expect(rec.receivedOps, 0);
      },
    );

    test('a 16 KiB BLE repeat sync behind the gap dropped mid-stream: it '
        'carried only duplicates, so no record and no "arrived" text claims '
        'changes got; the next session completes', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel", spy: true);
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      await syncByLink(b, a);
      a.clock.offset = _day * 10;
      await a.addExpense(s.g, payer: s.a, owers: [s.a, s.b], description: 'X');
      a.clock.offset = Duration.zero;
      await a.addExpenses(s, 300, base: 2000);
      await syncByLink(b, a);
      final held = b.opCount(s.g);
      final canon = b.canonical;

      for (final drop in [9, 13, 17]) {
        final dups = b.spy.duplicatesIgnored;
        final before = (await b.records()).length;
        await a.engine.startHosting();
        final peer = await b.find(a, transports: 2);
        b.lan.failConnect = true;
        b.ble.dropAfterFrames = drop;
        Object? out;
        try {
          out = await b.engine.syncWith(peer);
        } on SyncException catch (e) {
          out = e;
        }
        b.lan.failConnect = false;
        b.ble.dropAfterFrames = null;
        await waitFor(() => a.engine.status.session is! SessionActive);
        expect(out, isA<SyncException>(), reason: 'drop at $drop');
        final e = out as SyncException;
        expect(
          b.spy.duplicatesIgnored,
          greaterThan(dups),
          reason: 'drop at $drop: duplicates came over the wire',
        );
        expect(b.opCount(s.g), held);
        expect(b.canonical, canon);
        final recs = await b.records();
        expect(recs.length, before + 1);
        expect(recs.first.receivedOps, 0, reason: 'drop at $drop');
        expect(recs.first.outcome, isNot(SyncOutcome.completed));
        // The failed screen says "nothing lost" unless partial.receivedOps
        // is above 0.
        expect(e.partial?.receivedOps ?? 0, 0, reason: 'drop at $drop');
      }
      final again = await syncByLink(b, a);
      expect(again.receivedOps, 0);
      expect((await b.records()).first.outcome, SyncOutcome.completed);
      expect(b.opCount(s.g), held);
    });

    test('once real time reaches the stamp: got 1 (X) and the gap closes; '
        'a repeat after that got 0 and sent 0', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final s = await gap(a, b);
      a.clock.offset += _day * 10;
      b.clock.offset += _day * 10;
      await a.ledger.recheckClock();
      final r = await syncByLink(b, a);
      expect(r.receivedOps, 1);
      expect(r.receivedByGroup[s.g], 1);
      expect(b.canonical, a.canonical);
      expect(unshared(a, s.g), 0);
      final again = await syncByLink(b, a);
      expect(again.receivedOps, 0);
      expect(again.sentOps, 0);
    });
  });

  group('regression around the fix', () {
    test('5 repeat syncs on a clean pair: op count, snapshot unchanged, got '
        'and sent 0, five records added', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final s = await a.seedGroup(expenses: 3);
      await b.join(a, s.g);
      final first = await syncByLink(b, a);
      expect(first.receivedOps, a.opCount(s.g));
      expect(first.receivedOps, _sum(first.receivedByGroup));
      final before = (await b.records()).length;
      final canon = b.canonical;
      for (var i = 0; i < 5; i++) {
        final r = await syncByLink(b, a);
        expect(r.receivedOps, 0);
        expect(r.sentOps, 0);
        expect(b.canonical, canon);
      }
      expect((await b.records()).length, before + 5);
    });

    test('interrupted fresh BLE sync: partial iff something stored or '
        'acknowledged; partial.receivedOps equals stored ops', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final s = await a.seedGroup(expenses: 0);
      await b.join(a, s.g);
      await syncByLink(b, a);
      await a.addExpenses(s, 300, base: 2000);
      var stored = b.opCount(s.g);
      for (final drop in [8, 12, 16]) {
        await a.engine.startHosting();
        final peer = await b.find(a, transports: 2);
        b.lan.failConnect = true;
        b.ble.dropAfterFrames = drop;
        Object? out;
        try {
          out = await b.engine.syncWith(peer);
        } on SyncException catch (e) {
          out = e;
        }
        b.lan.failConnect = false;
        b.ble.dropAfterFrames = null;
        await waitFor(() => a.engine.status.session is! SessionActive);
        final now = b.opCount(s.g);
        final rec = (await b.records()).first;
        if (out is SyncException) {
          expect(rec.receivedOps, now - stored, reason: 'drop at $drop');
          expect(out.partial?.receivedOps ?? 0, now - stored);
          expect(
            rec.outcome,
            now > stored || rec.sentOps > 0
                ? SyncOutcome.partial
                : SyncOutcome.failed,
          );
        }
        stored = now;
      }
      await syncByLink(b, a);
      expect(b.canonical, a.canonical);
      expect(b.opCount(s.g), a.opCount(s.g));
    });
  });
  group('defects', () {
    test(
      'SYNC-R41-01: A says "Sent 2 changes" on every sync behind a held-back '
      'op while its badge still counts both unshared and B stored nothing',
      skip:
          'QA SYNC-R41-01: Sync summary and history count held-back and '
          're-sent ops as changes sent',
      () async {
        final a = await phone('a', "Alex's Pixel");
        final b = await phone('b', "Priya's Pixel");
        final s = await gap(a, b);
        expect(unshared(a, s.g), 2, reason: 'X and Y not shared');
        for (var i = 0; i < 3; i++) {
          final before = (await a.records()).length;
          final r = await syncByLink(b, a);
          expect(r.receivedOps, 0, reason: 'B stored nothing');
          await waitFor(() async => (await a.records()).length > before);
          // A's session screen, Sync history and Activity show
          // S.sentAndGot / S.sentGot(record.sentOps, ...).
          final rec = (await a.records()).first;
          expect(unshared(a, s.g), 2, reason: 'still not shared');
          expect(
            rec.sentOps,
            0,
            reason:
                '"Sent ${rec.sentOps} changes" while B stored none and '
                'A still shows them as not shared',
          );
        }
      },
    );
  });
}
