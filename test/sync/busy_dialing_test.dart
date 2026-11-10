// Regression tests around a phone whose own Sync is still dialing when
// another phone asks (SYNC-R3-01, SYNC-R3-02): Cancel during the wait for
// the other phone's dial, and a third phone that is not the one dialed.
// Also Cancel while the own dial is still connecting (SYNC-R4-01).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/hosting_details.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../qa/sync/qa_phone.dart';

/// A [MemoryTransport] whose connects take [delay], and whose sightings
/// can be rewritten (e.g. to the cut name a real advert carries).
final class _SlowTransport implements SyncTransport, HostingDetails {
  _SlowTransport(this.inner, {this.delay});
  final MemoryTransport inner;
  final Duration? delay;
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
    return inner.connect(peer, timeout: timeout);
  }

  /// Connect attempts so far.
  int connects = 0;

  @override
  Future<void> dispose() => inner.dispose();
}

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  setUp(() => hub = MemoryTransportHub());
  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
  });

  Future<Object> tap(QaPhone p, NearbyPeer to) =>
      p.engine.syncWith(to).then<Object>((s) => s, onError: (Object e) => e);

  /// Alex (fast) and Priya, whose connects take [priyaDelay], sharing a
  /// group; plus Carol named [carolName] when given.
  Future<(QaPhone, QaPhone, QaPhone?, GroupId)> phonesFor({
    required Duration priyaDelay,
    String alexName = "Alex's Pixel",
    String? carolName,
    void Function(_SlowTransport priyaT)? onPriya,
  }) async {
    final alex = await QaPhone.create(hub, 'a', alexName);
    final priya = await QaPhone.create(
      hub,
      'b',
      "Priya's Pixel",
      wrap: (t) {
        final w = _SlowTransport(t, delay: priyaDelay);
        onPriya?.call(w);
        return w;
      },
    );
    phones.addAll([alex, priya]);
    final seed = await alex.seedGroup(expenses: 2);
    await priya.join(alex, seed.g);
    QaPhone? carol;
    if (carolName != null) {
      carol = await QaPhone.create(hub, 'c', carolName);
      phones.add(carol);
      await carol.join(alex, seed.g);
    }
    return (alex, priya, carol, seed.g);
  }

  group('SYNC-R3-01: Cancel during the wait for the other phone\'s dial', () {
    test('frees the engine: the other phone\'s dial is then served as an '
        'ordinary inbound sync, and Alex records a cancelled Sync', () async {
      final (alex, priya, _, g) = await phonesFor(
        priyaDelay: const Duration(seconds: 5),
      );
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      final toAlex = await priya.find(alex);
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fa = tap(alex, toPriya);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await alex.engine.cancel();
      final a = await fa.timeout(const Duration(seconds: 1));
      expect(
        a,
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.cancelled,
        ),
      );
      // Free right away: not showing a Sync in progress.
      expect(alex.engine.status.session, isNot(isA<SessionActive>()));
      expect(
        alex.engine.status.session,
        isA<SessionFailed>().having(
          (s) => s.failure,
          'failure',
          SyncFailure.cancelled,
        ),
      );
      // Priya's dial arrives at ~5 s and is an ordinary sync now.
      final p = await fp.timeout(const Duration(seconds: 10));
      expect(p, isA<SyncSummary>(), reason: '$p');
      expect(priya.opCount(g), alex.opCount(g));
      final records = await alex.records();
      expect(
        records.map((r) => r.outcome),
        containsAll([SyncOutcome.cancelled, SyncOutcome.completed]),
      );
    });

    test('Cancel with nothing waiting changes nothing for the next Sync',
        () async {
      final (alex, priya, _, g) = await phonesFor(priyaDelay: Duration.zero);
      await priya.engine.startHosting();
      await alex.engine.cancel();
      final s = await alex.engine.syncWith(await alex.find(priya));
      expect(s.receivedOps + s.sentOps, greaterThanOrEqualTo(0));
      expect(priya.opCount(g), alex.opCount(g));
    });
  });

  group('SYNC-R3-02: a third phone asks a phone that is dialing', () {
    Future<(Object, Duration, SessionStatus)> carolTaps(
      QaPhone carol,
      QaPhone priya,
      QaPhone alex,
    ) async {
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toAlex = await priya.find(alex);
      final toPriya = await carol.find(priya);
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final watch = Stopwatch()..start();
      Duration? settledAt;
      final fc = tap(
        carol,
        toPriya,
      ).whenComplete(() => settledAt = watch.elapsed);
      await Future<void>.delayed(const Duration(milliseconds: 2800));
      final during = carol.engine.status.session;
      final c = await fc.timeout(const Duration(seconds: 20));
      expect(await fp.timeout(const Duration(seconds: 10)), isA<SyncSummary>());
      return (c, settledAt!, during);
    }

    test('Carol hosting too: told "someone else" after one handshake '
        'timeout, no wait for a dial that is not coming', () async {
      final (alex, priya, carol, _) = await phonesFor(
        priyaDelay: const Duration(seconds: 3),
        carolName: "Carol's Pixel",
      );
      await carol!.engine.startHosting();
      final (c, took, during) = await carolTaps(carol, priya, alex);
      expect(
        c,
        isA<SyncException>().having(
          (e) => e.message,
          'message',
          endsWith('Starting its own sync with someone else'),
        ),
      );
      expect(took, lessThan(const Duration(milliseconds: 2800)));
      expect(during, isNot(isA<SessionActive>()));
      expect(carol.engine.status.session, isNot(isA<SessionActive>()));
    });

    test('Carol not hosting: no wait even when her name matches the phone '
        'being dialed (nobody can dial her)', () async {
      final (alex, priya, carol, _) = await phonesFor(
        priyaDelay: const Duration(seconds: 3),
        carolName: "Alex's Pixel",
      );
      final (c, took, during) = await carolTaps(carol!, priya, alex);
      expect(
        c,
        isA<SyncException>().having(
          (e) => e.message,
          'message',
          endsWith('Starting its own sync'),
        ),
        reason: 'the names match, so Priya cannot rule Carol out',
      );
      expect(took, lessThan(const Duration(milliseconds: 2800)));
      expect(during, isNot(isA<SessionActive>()));
    });

    test('a mutual Sync whose advert cut the dialed phone\'s long name '
        'still serves the slow dial', () async {
      const longName = 'Alexander Fernandes-Iyer Pixel 8 Pro';
      final (alex, priya, _, g) = await phonesFor(
        priyaDelay: const Duration(seconds: 3),
        alexName: longName,
        onPriya: (t) => t.rewrite = (p) => DiscoveredPeer(
          kind: p.kind,
          address: p.address,
          // What a Nearby or BLE advert carries: the first 24 runes.
          name: String.fromCharCodes(p.name.runes.take(24)),
          advertId: p.advertId,
          groupTokens: p.groupTokens,
          windowTag: p.windowTag,
          moreGroups: p.moreGroups,
        ),
      );
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      await priya.engine.startDiscovery();
      final toAlex = await priya.engine
          .watchNearby()
          .firstWhere((l) => l.isNotEmpty)
          .timeout(const Duration(seconds: 3))
          .then((l) => l.first);
      expect(toAlex.name, isNot(longName));
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fa = tap(alex, toPriya);
      final results = await Future.wait([fa, fp])
          .timeout(const Duration(seconds: 20));
      expect(results, everyElement(isA<SyncSummary>()), reason: '$results');
      expect(priya.opCount(g), alex.opCount(g));
    });
  });

  group('SYNC-R4-01: Cancel while a connect attempt hangs', () {
    test('the engine is free at once: the other phone can then sync with '
        'it, and the late channel is closed unused', () async {
      final priyaTs = <_SlowTransport>[];
      final (alex, priya, _, g) = await phonesFor(
        priyaDelay: const Duration(seconds: 3),
        onPriya: priyaTs.add,
      );
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toAlex = await priya.find(alex);
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await priya.engine.cancel();
      expect(
        await fp.timeout(const Duration(milliseconds: 500)),
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.cancelled,
        ),
      );
      expect(
        priya.engine.status.session,
        isA<SessionFailed>().having(
          (s) => s.failure,
          'failure',
          SyncFailure.cancelled,
        ),
      );
      // Alex's Sync on Priya now runs at once, not "Syncing with another
      // phone".
      final s = await alex.engine
          .syncWith(await alex.find(priya))
          .timeout(const Duration(seconds: 2));
      expect(s, isA<SyncSummary>());
      expect(priya.opCount(g), alex.opCount(g));
      // The abandoned attempt connects at ~3 s: closed, never a sync.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(alex.engine.status.session, isNot(isA<SessionActive>()));
      expect(priya.engine.status.session, isNot(isA<SessionActive>()));
      final alexRecords = await alex.records();
      expect(
        alexRecords.where((r) => r.outcome == SyncOutcome.completed),
        hasLength(1),
      );
      final priyaRecords = await priya.records();
      expect(
        priyaRecords.map((r) => r.outcome),
        unorderedEquals([SyncOutcome.cancelled, SyncOutcome.completed]),
      );
      expect(priyaTs.fold(0, (n, t) => n + t.connects), 1);
    });

    test('Cancel before the next route: no route after it is tried',
        () async {
      final priyaTs = <_SlowTransport>[];
      final (alex, priya, _, _) = await phonesFor(
        priyaDelay: const Duration(seconds: 2),
        onPriya: priyaTs.add,
      );
      await alex.engine.startHosting();
      final toAlex = await priya.find(alex, transports: 2);
      expect(toAlex.transports, hasLength(2));
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await priya.engine.cancel();
      expect(
        await fp.timeout(const Duration(milliseconds: 500)),
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.cancelled,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(priyaTs.fold(0, (n, t) => n + t.connects), 1);
      expect(alex.engine.status.session, isNot(isA<SessionActive>()));
    });

    test('a Sync right after the Cancel runs normally', () async {
      final (alex, priya, _, g) = await phonesFor(
        priyaDelay: const Duration(milliseconds: 1500),
      );
      await alex.engine.startHosting();
      final toAlex = await priya.find(alex);
      final first = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await priya.engine.cancel();
      await first;
      final s = await priya.engine
          .syncWith(toAlex)
          .timeout(const Duration(seconds: 5));
      expect(s, isA<SyncSummary>());
      expect(priya.opCount(g), alex.opCount(g));
    });
  });
}
