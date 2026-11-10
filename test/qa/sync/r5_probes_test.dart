// QA SYNC round 5: probes around the round 4 fixes (SYNC-R4-01 Cancel
// while a connect hangs, SYNC-R3-02 "Starting its own sync" carrying the
// dialed phone's advert ids), through the real DefaultSyncEngine and
// Ledger over MemoryTransport.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/hosting_details.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'qa_phone.dart';

/// A [MemoryTransport] whose connects wait [delay] first (a route that
/// hangs), and whose sightings can be rewritten.
final class _Slow implements SyncTransport, HostingDetails {
  _Slow(this.inner, {this.delay});
  final MemoryTransport inner;
  Duration? delay;
  int connects = 0;
  int opened = 0;
  DiscoveredPeer Function(DiscoveredPeer)? rewrite;

  @override
  Future<List<String>> hostAddresses() => inner.hostAddresses();
  @override
  Future<String?> wifiName() => inner.wifiName();
  @override
  bool isLinkHost(String address) => inner.isLinkHost(address);
  @override
  TransportKind get kind => inner.kind;
  @override
  Future<TransportAvailability> availability() => inner.availability();
  @override
  Future<TransportAvailability> requestPermissions() =>
      inner.requestPermissions();
  @override
  Future<void> startAdvertising(AdvertiseInfo info) =>
      inner.startAdvertising(info);
  @override
  Future<void> stopAdvertising() => inner.stopAdvertising();
  @override
  Stream<FrameChannel> get inbound => inner.inbound;
  @override
  Stream<DiscoveredPeer> discover() {
    final r = rewrite;
    return r == null ? inner.discover() : inner.discover().map(r);
  }

  @override
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    connects++;
    final d = delay;
    if (d != null) await Future<void>.delayed(d);
    final c = await inner.connect(peer, timeout: timeout);
    opened++;
    return c;
  }

  @override
  Future<void> dispose() => inner.dispose();
}

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];
  final slow = <String, List<_Slow>>{};

  setUp(() => hub = MemoryTransportHub());
  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
    slow.clear();
  });

  Future<Object> tap(QaPhone p, NearbyPeer to) =>
      p.engine.syncWith(to).then<Object>((s) => s, onError: (Object e) => e);

  Future<Object> tapLink(QaPhone p, String link) => p.engine
      .syncWithLink(link)
      .then<Object>((s) => s, onError: (Object e) => e);

  Matcher failsWith(SyncFailure f) =>
      isA<SyncException>().having((e) => e.failure, 'failure', f);

  Future<QaPhone> phone(String letter, String name, {Duration? delay}) async {
    final p = await QaPhone.create(
      hub,
      letter,
      name,
      wrap: (t) {
        final w = _Slow(t, delay: delay);
        (slow[letter] ??= []).add(w);
        return w;
      },
    );
    phones.add(p);
    return p;
  }

  void setDelay(String letter, Duration? d) {
    for (final t in slow[letter]!) {
      t.delay = d;
    }
  }

  int opened(String letter) => slow[letter]!.fold(0, (n, t) => n + t.opened);

  // --------------------------------------------------- R4-01 neighbourhood --

  group('R4-01 probes: Cancel while a connect hangs', () {
    test('Sync by connect link: Cancel ends it at once', () async {
      final alex = await phone(
        'a',
        "Alex's Pixel",
        delay: const Duration(seconds: 4),
      );
      final priya = await phone('b', "Priya's Pixel");
      final seed = await alex.seedGroup(expenses: 2);
      await priya.join(alex, seed.g);
      final host = await priya.engine.startHosting();
      final w = Stopwatch()..start();
      final fa = tapLink(alex, host.connectLink);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(alex.engine.status.session, isA<SessionActive>());
      await alex.engine.cancel();
      final a = await fa.timeout(const Duration(seconds: 10));
      expect(w.elapsed, lessThan(const Duration(milliseconds: 1300)));
      expect(a, failsWith(SyncFailure.cancelled));
      expect(alex.engine.status.session, isA<SessionFailed>());
    });

    test(
      'first sync of an invite (h= host hint): Cancel lets acceptInvite '
      'return at once, the group is joined, a later Sync delivers it',
      () async {
        final alex = await phone('a', "Alex's Pixel");
        final ravi = await phone(
          'c',
          "Ravi's Galaxy",
          delay: const Duration(seconds: 4),
        );
        final seed = await alex.seedGroup(expenses: 3);
        await alex.engine.startHosting();
        final link = await alex.engine.inviteLinkFor(seed.g);
        final w = Stopwatch()..start();
        final fj = ravi.engine.acceptInvite(link);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(ravi.engine.status.session, isA<SessionActive>());
        await ravi.engine.cancel();
        final j = await fj.timeout(const Duration(seconds: 10));
        expect(w.elapsed, lessThan(const Duration(milliseconds: 1300)));
        expect(j.firstSync, isNull);
        expect(j.alreadyMember, isFalse);
        expect(ravi.engine.status.session, isNot(isA<SessionActive>()));
        setDelay('c', null);
        final s = await ravi.engine
            .syncWith(await ravi.find(alex))
            .timeout(const Duration(seconds: 5));
        expect(s.receivedOps, alex.opCount(seed.g));
        expect(ravi.canonical, alex.canonical);
      },
    );

    test('the abandoned connect lands during the next live Sync with the same '
        'phone: that Sync is not disturbed and keeps pushing', () async {
      final alex = await phone(
        'a',
        "Alex's Pixel",
        delay: const Duration(seconds: 2),
      );
      final priya = await phone('b', "Priya's Pixel");
      final seed = await alex.seedGroup(expenses: 2);
      await priya.join(alex, seed.g);
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      final first = tap(alex, toPriya);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await alex.engine.cancel();
      expect(
        await first.timeout(const Duration(seconds: 1)),
        failsWith(SyncFailure.cancelled),
      );
      // Again at once, now over a quick route, and kept open (LIVE).
      setDelay('a', null);
      alex.engine.liveMode = true;
      priya.engine.liveMode = true;
      final s = await alex.engine
          .syncWith(toPriya)
          .timeout(const Duration(seconds: 5));
      expect(s, isA<SyncSummary>());
      expect(priya.opCount(seed.g), alex.opCount(seed.g));
      // The abandoned attempt opens at ~2 s and is closed by the engine.
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(opened('a'), 2);
      // LIVE shows as SessionCompleted; the session itself must stay up.
      expect(
        (await alex.records()).where((r) => r.outcome == SyncOutcome.completed),
        isEmpty,
        reason: 'the live session ended when the abandoned connect landed',
      );
      await alex.addExpense(
        seed.g,
        payer: seed.a,
        owers: [seed.a, seed.b],
        total: 777,
        description: 'After the stray connect',
      );
      expect(
        await waitFor(() => priya.opCount(seed.g) == alex.opCount(seed.g)),
        isTrue,
        reason: 'the live session no longer pushes',
      );
      expect(priya.canonical, alex.canonical);
      final recs = await alex.records();
      expect(
        recs.where((r) => r.outcome == SyncOutcome.cancelled),
        hasLength(1),
      );
    });

    test('the abandoned connect fails later (host gone): no stray error, '
        'engine idle and usable', () async {
      final alex = await phone(
        'a',
        "Alex's Pixel",
        delay: const Duration(seconds: 2),
      );
      final priya = await phone('b', "Priya's Pixel");
      final seed = await alex.seedGroup(expenses: 1);
      await priya.join(alex, seed.g);
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      final fa = tap(alex, toPriya);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await alex.engine.cancel();
      await priya.engine.stopHosting();
      expect(
        await fa.timeout(const Duration(seconds: 1)),
        failsWith(SyncFailure.cancelled),
      );
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(alex.engine.status.session, isA<SessionFailed>());
      await priya.engine.startHosting();
      setDelay('a', null);
      expect(
        await alex.engine
            .syncWith(await alex.find(priya))
            .timeout(const Duration(seconds: 5)),
        isA<SyncSummary>(),
      );
    });

    test('dispose while a connect hangs: returns promptly, no stray error '
        'when the attempt lands', () async {
      final alex = await phone(
        'a',
        "Alex's Pixel",
        delay: const Duration(seconds: 2),
      );
      final priya = await phone('b', "Priya's Pixel");
      final seed = await alex.seedGroup(expenses: 1);
      await priya.join(alex, seed.g);
      await priya.engine.startHosting();
      final fa = tap(alex, await alex.find(priya));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final w = Stopwatch()..start();
      await alex.engine.dispose().timeout(const Duration(seconds: 3));
      expect(w.elapsed, lessThan(const Duration(milliseconds: 1000)));
      expect(
        await fa.timeout(const Duration(seconds: 1)),
        isA<SyncException>(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(priya.engine.status.session, isNot(isA<SessionActive>()));
    });

    test('Cancel with two hanging routes, then a third phone syncs with the '
        'cancelled phone at once', () async {
      final alex = await phone(
        'a',
        "Alex's Pixel",
        delay: const Duration(seconds: 3),
      );
      final priya = await phone('b', "Priya's Pixel");
      final carol = await phone('c', "Carol's Pixel");
      final seed = await alex.seedGroup(expenses: 2);
      await priya.join(alex, seed.g);
      await carol.join(alex, seed.g);
      await priya.engine.startHosting();
      await alex.engine.startHosting();
      final toPriya = await alex.find(priya, transports: 2);
      final fa = tap(alex, toPriya);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await alex.engine.cancel();
      expect(
        await fa.timeout(const Duration(seconds: 1)),
        failsWith(SyncFailure.cancelled),
      );
      final w = Stopwatch()..start();
      final c = await tap(
        carol,
        await carol.find(alex),
      ).timeout(const Duration(seconds: 5));
      expect(c, isA<SyncSummary>(), reason: '$c');
      expect(w.elapsed, lessThan(const Duration(milliseconds: 1500)));
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(slow['a']!.fold(0, (n, t) => n + t.connects), 1);
    });
  });

  // --------------------------------------------------- R3-02 neighbourhood --

  group('R3-02 probes: advert ids with "Starting its own sync"', () {
    test('mutual Sync between two phones of the same model ("Pixel 8") from '
        'the Nearby list still serves the slow dial', () async {
      final alex = await phone('a', 'Pixel 8');
      final priya = await phone(
        'b',
        'Pixel 8',
        delay: const Duration(seconds: 3),
      );
      final seed = await alex.seedGroup(expenses: 2);
      await priya.join(alex, seed.g);
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      final toAlex = await priya.find(alex);
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fa = tap(alex, toPriya);
      final results = await Future.wait([fa, fp])
          .timeout(const Duration(seconds: 20));
      expect(results, everyElement(isA<SyncSummary>()), reason: '$results');
      expect(priya.canonical, alex.canonical);
    });

    test(
      'Alex and Carol share a model, Priya dials Alex from the Nearby '
      'list: Carol is told within one handshake timeout, then syncs',
      () async {
        final alex = await phone('a', 'Pixel 8');
        final priya = await phone(
          'b',
          'Pixel 8 Pro',
          delay: const Duration(seconds: 3),
        );
        final carol = await phone('c', 'Pixel 8');
        final seed = await alex.seedGroup(expenses: 2);
        await priya.join(alex, seed.g);
        await carol.join(alex, seed.g);
        await alex.engine.startHosting();
        await priya.engine.startHosting();
        // Priya sees only Alex when she taps him; Carol starts hosting after.
        final toAlex = await priya.find(alex);
        await carol.engine.startHosting();
        final toPriya = await carol.find(priya);
        final fp = tap(priya, toAlex);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final w = Stopwatch()..start();
        Duration? took;
        final fc = tap(carol, toPriya).whenComplete(() => took = w.elapsed);
        await Future<void>.delayed(const Duration(milliseconds: 2800));
        expect(carol.engine.status.session, isNot(isA<SessionActive>()));
        final c = await fc.timeout(const Duration(seconds: 10));
        expect(c, failsWith(SyncFailure.peerUnreachable));
        expect(took!, lessThan(const Duration(milliseconds: 2800)));
        expect(
          await fp.timeout(const Duration(seconds: 10)),
          isA<SyncSummary>(),
        );
        expect(priya.canonical, alex.canonical);
        // Carol's next tap, once Priya is free, runs.
        expect(
          await tap(carol, toPriya).timeout(const Duration(seconds: 5)),
          isA<SyncSummary>(),
        );
        expect(carol.canonical, alex.canonical);
      },
    );

    test(
      'Priya dials a phone whose sighting carries no advert id (older '
      'advert): a same-named Carol still waits (documented fallback)',
      () async {
        final alex = await phone('a', 'Pixel 8');
        final priya = await phone(
          'b',
          "Priya's Pixel",
          delay: const Duration(seconds: 3),
        );
        final carol = await phone('c', 'Pixel 8');
        for (final t in slow['b']!) {
          t.rewrite = (p) => DiscoveredPeer(
            kind: p.kind,
            address: p.address,
            name: p.name,
            groupTokens: p.groupTokens,
            windowTag: p.windowTag,
            moreGroups: p.moreGroups,
          );
        }
        final seed = await alex.seedGroup(expenses: 2);
        await priya.join(alex, seed.g);
        await carol.join(alex, seed.g);
        await alex.engine.startHosting();
        await priya.engine.startHosting();
        final toAlex = await priya.find(alex);
        expect(toAlex.advertId, isNull);
        await carol.engine.startHosting();
        final toPriya = await carol.find(priya);
        final fp = tap(priya, toAlex);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final w = Stopwatch()..start();
        final c = await tap(
          carol,
          toPriya,
        ).timeout(const Duration(seconds: 15));
        expect(c, failsWith(SyncFailure.peerUnreachable));
        // Characterise only: the wait is bounded (connect + handshake).
        expect(w.elapsed, lessThan(const Duration(seconds: 7)));
        expect(
          await fp.timeout(const Duration(seconds: 10)),
          isA<SyncSummary>(),
        );
      },
    );

    test('SYNC-R5-01: a phone renamed while hosting keeps advertising its old '
        'name, so its mutual Sync is refused as "someone else"', () async {
      // Alex is visible (hosting goes on when the Sync screen closes), then
      // renames the phone in Settings. The advert keeps "Pixel 8" until the
      // next token window (up to 10 min) while HELLO says "Alex's phone".
      // Both tap Sync on each other; Priya's dial is slow (3 s).
      final alex = await phone('a', 'Pixel 8');
      final priya = await phone(
        'b',
        "Priya's Pixel",
        delay: const Duration(seconds: 3),
      );
      final seed = await alex.seedGroup(expenses: 2);
      await priya.join(alex, seed.g);
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      await alex.settings.setDeviceName("Alex's phone");
      expect(alex.deviceName, "Alex's phone");
      await priya.engine.startDiscovery();
      final seen = await priya.engine
          .watchNearby()
          .firstWhere((l) => l.isNotEmpty)
          .timeout(const Duration(seconds: 3));
      await Future<void>.delayed(const Duration(seconds: 1));
      final now = await priya.engine.watchNearby().first.timeout(
        const Duration(seconds: 3),
      );
      final toAlex = now.isEmpty ? seen.first : now.first;
      final toPriya = await alex.find(priya);
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fa = tap(alex, toPriya);
      final results = await Future.wait([fa, fp])
          .timeout(const Duration(seconds: 20));
      expect(
        results,
        everyElement(isA<SyncSummary>()),
        reason: 'advertised as "${toAlex.name}" after the rename: $results',
      );
      expect(toAlex.name, "Alex's phone");
    }, skip: 'SYNC-R5-01');
  });
}
