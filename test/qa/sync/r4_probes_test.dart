// QA SYNC round 4: probes around the round 3 fixes (SYNC-R3-01 Cancel
// during the wait for the other phone's dial, SYNC-R3-02 a third phone
// asking a phone that is dialing someone else), through the real
// DefaultSyncEngine and Ledger over MemoryTransport.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/hosting_details.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'qa_phone.dart';

/// A [MemoryTransport] whose connects wait [delay] first, and whose
/// sightings can be rewritten (what a real advert would carry).
final class _Slow implements SyncTransport, HostingDetails {
  _Slow(this.inner, {this.delay});
  final MemoryTransport inner;
  Duration? delay;
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
    final d = delay;
    if (d != null) await Future<void>.delayed(d);
    return inner.connect(peer, timeout: timeout);
  }

  @override
  Future<void> dispose() => inner.dispose();
}

extension<T> on T {
  T also(void Function(T) f) {
    f(this);
    return this;
  }
}

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  /// The wrapped transports of each phone, by device name.
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

  /// Alex ('a', the lower id) and Priya ('b'), sharing a group; their
  /// connects take [alexDelay] / [priyaDelay]. Carol ('c') joins when
  /// [carolName] is given.
  Future<(QaPhone, QaPhone, QaPhone?, GroupId)> phonesFor({
    Duration? alexDelay,
    Duration? priyaDelay,
    String alexName = "Alex's Pixel",
    String priyaName = "Priya's Pixel",
    String? carolName,
  }) async {
    final alex = await QaPhone.create(
      hub,
      'a',
      alexName,
      wrap: (t) => _Slow(t, delay: alexDelay),
    );
    final priya = await QaPhone.create(
      hub,
      'b',
      priyaName,
      wrap: (t) => _Slow(t, delay: priyaDelay)
        ..also((w) => (slow[priyaName] ??= []).add(w)),
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

  // ------------------------------------------------- R3-01 neighbourhood --

  group('R3-01 probes: Cancel while waiting for the other phone\'s dial', () {
    test('the higher id phone cancels its wait: cancelled at once, the slow '
        'dial is then an ordinary sync', () async {
      // Alex (lower id) dials slowly; Priya taps 5 ms later and is refused
      // by Alex with "Starting its own sync" at ~2 s, then waits.
      final (alex, priya, _, g) = await phonesFor(
        alexDelay: const Duration(seconds: 5),
      );
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      final toAlex = await priya.find(alex);
      final fa = tap(alex, toPriya);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await priya.engine.cancel();
      final p = await fp.timeout(const Duration(seconds: 1));
      expect(p, failsWith(SyncFailure.cancelled));
      expect(priya.engine.status.session, isNot(isA<SessionActive>()));
      final a = await fa.timeout(const Duration(seconds: 10));
      expect(a, isA<SyncSummary>(), reason: '$a');
      expect(priya.opCount(g), alex.opCount(g));
      expect(priya.canonical, alex.canonical);
    });

    test('Cancel, then Sync again at once: no stuck engine, both phones '
        'end equal', () async {
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
      expect(
        await fa.timeout(const Duration(seconds: 1)),
        failsWith(SyncFailure.cancelled),
      );
      final again = tap(alex, toPriya);
      final results = await Future.wait([
        again,
        fp,
      ]).timeout(const Duration(seconds: 20));
      expect(
        results.whereType<SyncSummary>(),
        isNotEmpty,
        reason: '$results',
      );
      expect(
        results,
        everyElement(
          predicate(
            (r) =>
                r is SyncSummary ||
                (r is SyncException &&
                    r.failure == SyncFailure.peerUnreachable &&
                    r.message.contains('busy')),
          ),
        ),
        reason: '$results',
      );
      expect(priya.opCount(g), alex.opCount(g));
      expect(alex.engine.status.session, isNot(isA<SessionActive>()));
      expect(priya.engine.status.session, isNot(isA<SessionActive>()));
      // A later Sync still runs.
      expect(
        await alex.engine.syncWith(toPriya).timeout(const Duration(seconds: 5)),
        isA<SyncSummary>(),
      );
    });

    test('Cancel twice during the wait is harmless', () async {
      final (alex, priya, _, _) = await phonesFor(
        priyaDelay: const Duration(seconds: 4),
      );
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      final toAlex = await priya.find(alex);
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fa = tap(alex, toPriya);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await Future.wait([alex.engine.cancel(), alex.engine.cancel()]);
      expect(
        await fa.timeout(const Duration(seconds: 1)),
        failsWith(SyncFailure.cancelled),
      );
      expect(await fp.timeout(const Duration(seconds: 10)), isA<SyncSummary>());
      final recs = await alex.records();
      expect(
        recs.where((r) => r.outcome == SyncOutcome.cancelled),
        hasLength(1),
      );
    });

    test('hosting stops during the wait: the Sync ends at once (nothing '
        'more can arrive)', () async {
      final (alex, priya, _, _) = await phonesFor(
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
      final w = Stopwatch()..start();
      await alex.engine.stopHosting();
      final a = await fa.timeout(const Duration(seconds: 5));
      expect(w.elapsed, lessThan(const Duration(milliseconds: 500)));
      expect(a, isA<SyncException>(), reason: '$a');
      expect(alex.engine.status.session, isNot(isA<SessionActive>()));
      // Priya's dial then finds nobody hosting.
      await fp.timeout(const Duration(seconds: 10));
    });

    test('Cancel while the own dial is still connecting and the other '
        'phone\'s connection waits for a decision: never served as the '
        'cancelled Sync', () async {
      // Alex's own dial takes 3 s. Priya taps 5 ms later; her connection
      // reaches Alex at once and waits for Alex to learn whom it dials.
      final (alex, priya, _, g) = await phonesFor(
        alexDelay: const Duration(seconds: 3),
      );
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      final toAlex = await priya.find(alex);
      final fa = tap(alex, toPriya);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      await alex.engine.cancel();
      final a = await fa.timeout(const Duration(seconds: 10));
      expect(a, failsWith(SyncFailure.cancelled));
      final p = await fp.timeout(const Duration(seconds: 15));
      // Priya's Sync either ran as an ordinary inbound sync or was told
      // Alex is busy; it never runs as Alex's cancelled Sync, so Alex has
      // no completed record unless Priya's call succeeded too.
      final recs = await alex.records();
      final completed = recs.where((r) => r.outcome == SyncOutcome.completed);
      if (p is SyncSummary) {
        expect(completed, hasLength(1));
        expect(priya.opCount(g), alex.opCount(g));
      } else {
        expect(completed, isEmpty);
        expect(p, failsWith(SyncFailure.peerUnreachable));
      }
      expect(alex.engine.status.session, isNot(isA<SessionActive>()));
      expect(
        await alex.engine.syncWith(toPriya).timeout(const Duration(seconds: 8)),
        isA<SyncSummary>(),
      );
    });
  });

  // ----------------------------------------------------- new in round 4 --

  group('R4 findings', () {
    test(
      'SYNC-R4-01: Cancel while Connecting over a route that hangs ends the '
      'Sync at once, not when the connect attempt gives up',
      () async {
        // Alex's route to Priya hangs for 5 s (a LAN address behind Wi-Fi
        // client isolation answers nothing until the connect timeout,
        // 10 s in production). The Sync screen shows "Connecting" and a
        // Cancel button; the user taps it 500 ms in.
        final (alex, priya, _, _) = await phonesFor(
          alexDelay: const Duration(seconds: 5),
        );
        await priya.engine.startHosting();
        final toPriya = await alex.find(priya);
        final w = Stopwatch()..start();
        Duration? settled;
        final fa = tap(alex, toPriya).whenComplete(() => settled = w.elapsed);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(alex.engine.status.session, isA<SessionActive>());
        await alex.engine.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        final after = alex.engine.status.session;
        final a = await fa.timeout(const Duration(seconds: 10));
        expect(a, failsWith(SyncFailure.cancelled));
        expect(
          after,
          isNot(isA<SessionActive>()),
          reason:
              '1 s after Cancel the Sync screen still shows Connecting with '
              'its Cancel button',
        );
        expect(
          settled!,
          lessThan(const Duration(milliseconds: 1600)),
          reason:
              'syncWith ended only after $settled, when the hanging connect '
              'gave up; the engine stays busy until then',
        );
      },
      skip:
          'SYNC-R4-01: Cancel during Connecting waits for the current connect '
          'attempt to give up (up to the 10 s connect timeout)',
    );
  });

  // ------------------------------------------------- R3-02 neighbourhood --

  group('R3-02 probes: a third phone asks a phone that is dialing', () {
    /// Priya dials Alex (slow, 3 s) by [priyaDials]; Carol taps Sync on
    /// Priya 5 ms later. Returns Carol's result, when it settled, and
    /// Carol's status 2.8 s in.
    Future<(Object, Duration, SessionStatus)> run(
      QaPhone alex,
      QaPhone priya,
      QaPhone carol, {
      required Future<Object> Function() priyaDials,
      Duration lookAt = const Duration(milliseconds: 2800),
    }) async {
      final toPriya = await carol.find(priya);
      final fp = priyaDials();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final w = Stopwatch()..start();
      Duration? settled;
      final fc = tap(carol, toPriya).whenComplete(() => settled = w.elapsed);
      await Future<void>.delayed(lookAt);
      final during = carol.engine.status.session;
      final c = await fc.timeout(const Duration(seconds: 20));
      expect(await fp.timeout(const Duration(seconds: 10)), isA<SyncSummary>());
      return (c, settled!, during);
    }

    test('Priya dials Alex by connect link (device id known): Carol, '
        'hosting, is told "someone else" after one handshake timeout',
        () async {
      final (alex, priya, carol, _) = await phonesFor(
        priyaDelay: const Duration(seconds: 3),
        carolName: "Carol's Pixel",
      );
      final host = await alex.engine.startHosting();
      await priya.engine.startHosting();
      await carol!.engine.startHosting();
      final (c, took, during) = await run(
        alex,
        priya,
        carol,
        priyaDials: () => tapLink(priya, host.connectLink),
      );
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
    });

    test('connect link, Carol named like Alex: the device id still tells '
        'them apart', () async {
      final (alex, priya, carol, _) = await phonesFor(
        priyaDelay: const Duration(seconds: 3),
        carolName: "Alex's Pixel",
      );
      final host = await alex.engine.startHosting();
      await priya.engine.startHosting();
      await carol!.engine.startHosting();
      final (c, took, _) = await run(
        alex,
        priya,
        carol,
        priyaDials: () => tapLink(priya, host.connectLink),
      );
      expect(
        c,
        isA<SyncException>().having(
          (e) => e.message,
          'message',
          endsWith('someone else'),
        ),
      );
      expect(took, lessThan(const Duration(milliseconds: 2800)));
    });

    test('mutual Sync by connect link with a slow dial still serves the '
        'dial (the device id matches)', () async {
      final (alex, priya, _, g) = await phonesFor(
        priyaDelay: const Duration(seconds: 3),
      );
      final host = await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      final fp = tapLink(priya, host.connectLink);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fa = tap(alex, toPriya);
      final results = await Future.wait([
        fa,
        fp,
      ]).timeout(const Duration(seconds: 20));
      expect(results, everyElement(isA<SyncSummary>()), reason: '$results');
      expect(priya.opCount(g), alex.opCount(g));
    });

    test('mutual Sync by name where mDNS renamed the dialed phone '
        '"Alex\'s Pixel (2)" still serves the slow dial', () async {
      final (alex, priya, _, g) = await phonesFor(
        priyaDelay: const Duration(seconds: 3),
      );
      for (final t in slow["Priya's Pixel"]!) {
        t.rewrite = (p) => DiscoveredPeer(
          kind: p.kind,
          address: p.address,
          name: '${p.name} (2)',
          advertId: p.advertId,
          groupTokens: p.groupTokens,
          windowTag: p.windowTag,
          moreGroups: p.moreGroups,
        );
      }
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      await priya.engine.startDiscovery();
      final toAlex = await priya.engine
          .watchNearby()
          .firstWhere((l) => l.isNotEmpty)
          .timeout(const Duration(seconds: 3))
          .then((l) => l.first);
      expect(toAlex.name, endsWith('(2)'));
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fa = tap(alex, toPriya);
      final results = await Future.wait([
        fa,
        fp,
      ]).timeout(const Duration(seconds: 20));
      expect(results, everyElement(isA<SyncSummary>()), reason: '$results');
      expect(priya.opCount(g), alex.opCount(g));
    });

    test(
      'SYNC-R3-02: phones keep their default model name: a third phone with '
      'the same model as the phone being dialed still waits ~3 handshake '
      'timeouts on "Comparing"',
      () async {
        // The default device name is the phone model (bootstrap
        // _deviceName), so two friends with the same model share a name.
        // Priya dials Alex ("Pixel 8") slowly; Carol, also "Pixel 8" and
        // hosting, taps Sync on Priya.
        final (alex, priya, carol, _) = await phonesFor(
          priyaDelay: const Duration(seconds: 3),
          alexName: 'Pixel 8',
          carolName: 'Pixel 8',
        );
        await alex.engine.startHosting();
        await priya.engine.startHosting();
        await carol!.engine.startHosting();
        final toAlex = await priya.find(alex);
        final (c, took, during) = await run(
          alex,
          priya,
          carol,
          priyaDials: () => tap(priya, toAlex),
          // After Priya's own Sync with Alex is over (~3.2 s).
          lookAt: const Duration(milliseconds: 4000),
        );
        expect(c, failsWith(SyncFailure.peerUnreachable));
        expect(
          during,
          isNot(isA<SessionActive>()),
          reason:
              'Carol still shows Sync progress 4 s in, though Priya learned '
              'whom it dials at ~3 s and its Sync was over at ~3.2 s',
        );
        expect(
          took,
          lessThan(const Duration(milliseconds: 4000)),
          reason:
              'Carol was told only after $took (one handshake timeout is '
              '2 s; production timings make it ~30 s instead of ~10 s)',
        );
      },
      skip:
          'SYNC-R3-02: with the same device name (the default model name) '
          'the third phone still waits a connect plus a handshake timeout',
    );
  });
}
