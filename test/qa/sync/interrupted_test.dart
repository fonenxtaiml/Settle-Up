// QA SYNC-R1: interrupted syncs through the real engine. The link drops
// after N frames (MemoryTransport.dropAfterFrames); the outcome must be
// partial or failed, nothing applied twice, unshared counts honest, and the
// next session must complete and converge.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

void main() {
  late MemoryTransportHub hub;
  late QaPhone alex, priya;
  late QaSeed seed;

  setUp(() async {
    hub = MemoryTransportHub();
    alex = await QaPhone.create(hub, 'a', "Alex's Pixel", spyStore: true);
    priya = await QaPhone.create(hub, 'b', "Priya's Pixel", spyStore: true);
    seed = await alex.seedGroup(expenses: 0);
    await priya.join(alex, seed.g);
    await syncByLink(priya, alex);
  });

  tearDown(() async {
    await alex.dispose();
    await priya.dispose();
  });

  /// Waits until [p] recorded one more session than [before] (the
  /// responder is free again only once its session has ended).
  Future<void> recorded(QaPhone p, int before) async {
    expect(
      await waitFor(() async => (await p.records()).length > before),
      isTrue,
      reason: 'responder never finished its session',
    );
  }

  int unshared(QaPhone p) => p.snapshot.unsharedCounts[seed.g] ?? 0;

  /// Own ops of [p] that [other] does not hold.
  Future<int> reallyUnshared(QaPhone p, QaPhone other) async {
    final held = (await other.ledger.versionVector(seed.g))[p.deviceId];
    return p
        .opsOf(seed.g)
        .where((o) => o.deviceId == p.deviceId && o.counter > held)
        .length;
  }

  // Frames at 16 KiB with ~140 ops each way: OPS batches are mid-flight
  // for most drop points.
  for (final drop in [2, 4, 6, 7, 9, 11, 14, 18, 25, 33]) {
    test(
      'BLE-size frames, drop after $drop frames, both sides wrote',
      () async {
        await alex.addExpenses(seed, 140);
        await priya.addExpenses(seed, 140, base: 5000);
        final dupsBefore =
            alex.spy.duplicatesIgnored + priya.spy.duplicatesIgnored;

        alex.ble.dropAfterFrames = drop;
        final pBefore = (await priya.records()).length;
        await priya.engine.startHosting();
        final peer = await alex.find(priya, transports: 2);
        alex.lan.failConnect = true; // force the BLE route
        Object? outcome;
        try {
          outcome = await alex.engine.syncWith(peer);
        } on SyncException catch (e) {
          outcome = e;
        }
        expect(outcome, isA<SyncException>(), reason: 'drop at $drop');
        final e = outcome as SyncException;
        expect(
          e.failure,
          anyOf(SyncFailure.connectionLost, SyncFailure.timeout),
        );
        final aRec = (await alex.records()).first;
        expect(aRec.outcome, anyOf(SyncOutcome.partial, SyncOutcome.failed));
        // partial is reported iff something went through.
        if (aRec.sentOps > 0 || aRec.receivedOps > 0) {
          expect(aRec.outcome, SyncOutcome.partial);
          expect(e.partial, isNotNull);
        } else {
          expect(aRec.outcome, SyncOutcome.failed);
        }
        // The unshared badge never claims more is shared than really is.
        expect(
          unshared(alex),
          greaterThanOrEqualTo(await reallyUnshared(alex, priya)),
        );
        expect(
          unshared(priya),
          greaterThanOrEqualTo(await reallyUnshared(priya, alex)),
        );
        await recorded(priya, pBefore);

        // Resume: the next session completes, nothing applied twice.
        alex.ble.dropAfterFrames = null;
        final again = await alex.engine.syncWith(await alex.find(priya));
        expect(again.transport, TransportKind.ble);
        expect(alex.canonical, priya.canonical);
        expect(alex.opCount(seed.g), priya.opCount(seed.g));
        expect(alex.opCount(seed.g), 3 + 280);
        expect(
          alex.spy.duplicatesIgnored + priya.spy.duplicatesIgnored,
          dupsBefore,
          reason: 'ops already committed must not be re-sent',
        );
        expect(
          await alex.ledger.versionVector(seed.g),
          await priya.ledger.versionVector(seed.g),
        );
        expect(unshared(alex), 0);
        await waitFor(() => unshared(priya) == 0);
        expect(unshared(priya), 0);
        expect((await alex.records()).first.outcome, SyncOutcome.completed);
      },
    );
  }

  test('drop after the last ACK, before DONE/BYE: partial, then resumes '
      'with nothing to send', () async {
    // 1 op from Alex, nothing from Priya: HELLO x2, AUTH x2, VV x2,
    // DONE(R), OPS, DONE(I), ACK = 10 frames.
    await alex.addExpenses(seed, 1);
    alex.lan.dropAfterFrames = 10;
    final pBefore = (await priya.records()).length;
    final host = await priya.engine.startHosting();
    final err = await alex.engine
        .syncWithLink(host.connectLink)
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(err, isA<SyncException>());
    expect((err! as SyncException).partial?.sentOps, 1);
    expect((await alex.records()).first.outcome, SyncOutcome.partial);
    expect(priya.opCount(seed.g), alex.opCount(seed.g));
    expect(unshared(alex), 0, reason: 'the ACK arrived');
    await recorded(priya, pBefore);

    alex.lan.dropAfterFrames = null;
    final again = await alex.engine.syncWithLink(host.connectLink);
    expect((again.sentOps, again.receivedOps), (0, 0));
    expect(alex.spy.duplicatesIgnored + priya.spy.duplicatesIgnored, 0);
  });

  test('a drop before AUTH completes is failed (not partial) and leaves the '
      'engine usable', () async {
    await alex.addExpenses(seed, 5);
    alex.lan.dropAfterFrames = 3;
    final pBefore = (await priya.records()).length;
    final host = await priya.engine.startHosting();
    final err = await alex.engine
        .syncWithLink(host.connectLink)
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect((err! as SyncException).failure, SyncFailure.connectionLost);
    expect((await alex.records()).first.outcome, SyncOutcome.failed);
    expect(unshared(alex), 5);
    alex.lan.dropAfterFrames = null;
    await recorded(priya, pBefore);
    final again = await alex.engine.syncWithLink(host.connectLink);
    expect(again.sentOps, 5);
    expect(unshared(alex), 0);
  });

  test('repeated drops at growing points eventually move everything', () async {
    await alex.addExpenses(seed, 400);
    await priya.engine.startHosting();
    final peer = await alex.find(priya, transports: 2);
    alex.lan.failConnect = true;
    var sessions = 0;
    for (var drop = 9; drop < 200; drop += 9) {
      alex.ble.dropAfterFrames = drop;
      sessions++;
      final pBefore = (await priya.records()).length;
      try {
        await alex.engine.syncWith(peer);
      } on SyncException {
        // expected while the drop point is inside the exchange
      }
      await recorded(priya, pBefore);
      if (priya.opCount(seed.g) == alex.opCount(seed.g)) break;
    }
    alex.ble.dropAfterFrames = null;
    await alex.engine.syncWith(peer);
    expect(sessions, greaterThan(1));
    expect(priya.canonical, alex.canonical);
    expect(priya.spy.duplicatesIgnored, 0);
  });
}
