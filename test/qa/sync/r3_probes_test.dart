// QA SYNC round 3: probes around the round 2 fixes (SYNC-R2-01, R2-02):
// variations and neighbouring cases of each repro, through the real
// DefaultSyncEngine and Ledger over MemoryTransport.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/crypto/tokens.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/ble/ble_info.dart';
import 'package:settle_up/sync/transport/hosting_details.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/support/phone.dart' show groupIdOf, groupKeyOf;
import 'qa_phone.dart';

/// Delegates to a [MemoryTransport] with hooks: [connectHook] runs before
/// every connect (it may throw: a route that hangs and fails), the last
/// advert is kept in [advertised], and [rewrite] changes what discovery
/// reports (e.g. what a real Nearby/BLE/LAN advert would carry).
final class HookTransport implements SyncTransport, HostingDetails {
  HookTransport(this.inner, {this.connectHook, this.rewrite});
  final MemoryTransport inner;
  final Future<void> Function(Duration timeout)? connectHook;
  DiscoveredPeer Function(DiscoveredPeer)? rewrite;
  AdvertiseInfo? advertised;

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
  Future<void> startAdvertising(AdvertiseInfo info) {
    advertised = info;
    return inner.startAdvertising(info);
  }

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
    await connectHook?.call(timeout);
    return inner.connect(peer, timeout: timeout);
  }

  @override
  Future<void> dispose() => inner.dispose();
}

/// A route that hangs for its whole connect timeout, then fails (a LAN
/// address behind Wi-Fi client isolation).
Future<void> hangThenFail(Duration timeout) async {
  await Future<void>.delayed(timeout);
  throw TimeoutException('connect timed out', timeout);
}

Future<void> Function(Duration) slowBy(Duration d) =>
    (_) => Future<void>.delayed(d);

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

  // ------------------------------------------------ R2-02 neighbourhood --

  group('R2-02 probes: mutual Sync with a slow dial', () {
    Future<(QaPhone, QaPhone, QaSeed)> pair({
      Duration? alexDelay,
      Duration? priyaDelay,
      List<TransportKind> priyaKinds = const [
        TransportKind.lan,
        TransportKind.ble,
      ],
      Map<TransportKind, Future<void> Function(Duration)>? priyaHooks,
    }) async {
      final alex = await QaPhone.create(
        hub,
        'a',
        "Alex's Pixel",
        wrap: alexDelay == null
            ? null
            : (t) => HookTransport(t, connectHook: slowBy(alexDelay)),
      );
      final priya = await QaPhone.create(
        hub,
        'b',
        "Priya's Pixel",
        kinds: priyaKinds,
        wrap: (t) => HookTransport(
          t,
          connectHook:
              priyaHooks?[t.kind] ??
              (priyaDelay == null ? null : slowBy(priyaDelay)),
        ),
      );
      phones.addAll([alex, priya]);
      final seed = await alex.seedGroup(expenses: 3);
      await priya.join(alex, seed.g);
      return (alex, priya, seed);
    }

    for (final (label, alexMs, priyaMs, priyaFirst) in const [
      ('higher id slow 2.5 s, slow phone taps first', null, 2500, true),
      ('higher id slow 5 s, slow phone taps first', null, 5000, true),
      ('higher id slow 3 s, fast phone taps first', null, 3000, false),
      ('lower id slow 3 s, slow phone taps first', 3000, null, false),
      ('both slow 3 s', 3000, 3000, true),
    ]) {
      test('$label: both calls succeed and the phones converge', () async {
        final (alex, priya, seed) = await pair(
          alexDelay: alexMs == null ? null : Duration(milliseconds: alexMs),
          priyaDelay: priyaMs == null ? null : Duration(milliseconds: priyaMs),
        );
        await alex.engine.startHosting();
        await priya.engine.startHosting();
        final toPriya = await alex.find(priya);
        final toAlex = await priya.find(alex);
        final Future<Object> fa, fp;
        if (priyaFirst) {
          fp = tap(priya, toAlex);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          fa = tap(alex, toPriya);
        } else {
          fa = tap(alex, toPriya);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          fp = tap(priya, toAlex);
        }
        final results = await Future.wait([fa, fp])
            .timeout(const Duration(seconds: 20));
        // When the first tap's connection authenticates within the 5 ms
        // before the second tap, the second phone is already syncing with
        // the first one (its screen shows that session) and its own tap is
        // refused at once: not the case under test, but fine.
        bool ok(Object? r) =>
            r is SyncSummary ||
            (r is SyncException && r.message == 'A sync is already running');
        expect(
          results.whereType<SyncSummary>(),
          isNotEmpty,
          reason: '$results',
        );
        expect(results, everyElement(predicate(ok)), reason: '$results');
        expect(priya.opCount(seed.g), alex.opCount(seed.g));
        expect(priya.canonical, alex.canonical);
        // Neither engine is left busy.
        expect(alex.engine.status.session, isNot(isA<SessionActive>()));
        expect(priya.engine.status.session, isNot(isA<SessionActive>()));
      });
    }

    test('slow phone dials over 2 routes, the first hanging for its connect '
        'timeout: both calls succeed', () async {
      final (alex, priya, seed) = await pair(
        priyaHooks: {
          TransportKind.lan: hangThenFail,
          TransportKind.ble: slowBy(const Duration(milliseconds: 1500)),
        },
      );
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya, transports: 2);
      final toAlex = await priya.find(alex, transports: 2);
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fa = tap(alex, toPriya);
      final results = await Future.wait([fa, fp])
          .timeout(const Duration(seconds: 20));
      expect(results, everyElement(isA<SyncSummary>()), reason: '$results');
      expect(priya.canonical, alex.canonical);
      expect(priya.opCount(seed.g), alex.opCount(seed.g));
    });

    test(
      'SYNC-R3-01: Cancel while waiting for the slow phone\'s dial (after "Starting '
      'its own sync") stops the Sync at once and frees the engine',
      () async {
        // Priya's dial takes 5 s. Alex's connection is refused at ~2 s with
        // "Starting its own sync"; Alex then waits for Priya's dial. The user
        // taps Cancel on Alex at 2.5 s.
        final (alex, priya, _) = await pair(
          priyaDelay: const Duration(seconds: 5),
        );
        await alex.engine.startHosting();
        await priya.engine.startHosting();
        final toPriya = await alex.find(priya);
        final toAlex = await priya.find(alex);
        final fp = tap(priya, toAlex);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final watch = Stopwatch()..start();
        final fa = tap(alex, toPriya);
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        await alex.engine.cancel();
        final cancelledAt = watch.elapsed;
        final a = await fa.timeout(const Duration(seconds: 10));
        final settledAfter = watch.elapsed - cancelledAt;
        await fp.timeout(const Duration(seconds: 10));
        expect(
          a,
          isA<SyncException>().having(
            (e) => e.failure,
            'failure',
            SyncFailure.cancelled,
          ),
          reason:
              'the user tapped Cancel at 2.5 s; Alex got $a after '
              '${settledAfter.inMilliseconds} ms more',
        );
        expect(settledAfter, lessThan(const Duration(seconds: 1)));
      },
    );

    test(
      'SYNC-R3-02: a third phone that taps Sync on a phone still dialing someone '
      'else is told so within about one handshake timeout',
      () async {
        // Priya dials Alex slowly (3 s); Carol taps Sync on Priya meanwhile.
        // Before the R2-02 fix Carol was refused after one handshake timeout
        // (2 s here, 10 s in production).
        final (alex, priya, seed) = await pair(
          priyaDelay: const Duration(seconds: 3),
        );
        final carol = await QaPhone.create(hub, 'c', "Carol's Pixel");
        phones.add(carol);
        await carol.join(alex, seed.g);
        await alex.engine.startHosting();
        await priya.engine.startHosting();
        final toAlex = await priya.find(alex);
        final toPriya = await carol.find(priya);
        final fp = tap(priya, toAlex);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final watch = Stopwatch()..start();
        // When Carol's call settles (not when the test reads it below,
        // which is after the 4 s look at her status).
        Duration? settledAt;
        final fc = tap(
          carol,
          toPriya,
        ).whenComplete(() => settledAt = watch.elapsed);
        await Future<void>.delayed(const Duration(milliseconds: 4000));
        final during = carol.engine.status.session;
        final c = await fc.timeout(const Duration(seconds: 20));
        final took = settledAt!;
        expect(
          during,
          isNot(isA<SessionActive>()),
          reason:
              'at 4 s Carol\'s Sync screen still shows $during '
              '(${during is SessionActive ? during.progress.phase : ''})',
        );
        expect(
          await fp.timeout(const Duration(seconds: 10)),
          isA<SyncSummary>(),
        );
        expect(c, isA<SyncException>());
        expect(
          (c as SyncException).message,
          isNot(contains('another phone')),
          reason: 'Priya was dialing at that moment',
        );
        expect(
          took,
          lessThan(const Duration(milliseconds: 3000)),
          reason:
              'Carol waited ${took.inMilliseconds} ms for "$c" '
              '(handshake timeout 2 s, connect timeout 2 s); in production '
              'that is ~30 s with the Sync screen still showing progress',
        );
      },
    );
  });

  // ------------------------------------------------ R2-01 neighbourhood --

  group('R2-01 probes: adverts of a phone in many groups', () {
    /// The advert as a real transport of [kind] would decode it.
    DiscoveredPeer viaReal(String kind, AdvertiseInfo a, DiscoveredPeer p) {
      final decoded = switch (kind) {
        'nearby' => NearbyEndpointName.tryParse(
          NearbyEndpointName.of(a).encode(),
        )!.toPeer('E1'),
        'ble' => BleInfo.tryParse(BleInfo.of(a).encode())!.toPeer('uuid-1'),
        _ => MdnsSighting(
          name: a.deviceName,
          addresses: const ['192.168.1.20'],
          port: 47321,
          attributes: MdnsAdvert.of(a, 47321).attributes,
        ).toPeer()!,
      };
      return DiscoveredPeer(
        kind: p.kind,
        address: p.address,
        name: p.name,
        advertId: decoded.advertId,
        groupTokens: decoded.groupTokens,
        windowTag: decoded.windowTag,
        moreGroups: decoded.moreGroups,
      );
    }

    for (final (kind, groups) in const [
      ('nearby', 30),
      ('ble', 100),
      ('lan', 250),
    ]) {
      test('over $kind with $groups groups: a friend invited to the oldest '
          'group (never synced) gets Sync, the sync works, and the group '
          'then stays in the advert', () async {
        late HookTransport alexT;
        final alex = await QaPhone.create(
          hub,
          'a',
          "Alex's Pixel",
          kinds: const [TransportKind.lan],
          wrap: (t) => alexT = HookTransport(t),
        );
        late HookTransport priyaT;
        final priya = await QaPhone.create(
          hub,
          'b',
          "Priya's Pixel",
          kinds: const [TransportKind.lan],
          wrap: (t) => priyaT = HookTransport(t),
        );
        phones.addAll([alex, priya]);
        // Oldest group first, then many newer 1:1 friend groups.
        final seed = await alex.seedGroup(expenses: 2);
        for (var i = 1; i < groups; i++) {
          await alex.ledger.createGroup(
            NewGroup(
              name: 'Friend $i',
              type: GroupType.other,
              currency: 'INR',
              newMemberNames: ['F$i'],
            ),
          );
        }
        expect(alex.state.groups, hasLength(groups));
        await priya.join(alex, seed.g);
        // What Priya's scanner sees: Alex's advert as the real transport
        // would carry it.
        priyaT.rewrite = (p) => viaReal(kind, alexT.advertised!, p);
        await alex.engine.startHosting();
        final found = await priya.find(alex);
        expect(
          found.sharesGroups,
          isFalse,
          reason: 'the oldest group is cut from the advert',
        );
        expect(found.maySync, isTrue);
        final s = await priya.engine.syncWith(found);
        expect(s.receivedOps, greaterThan(0));
        expect(priya.opCount(seed.g), alex.opCount(seed.g));
        // Next advert (e.g. the next window): the synced group comes first.
        await alex.engine.stopHosting();
        await priya.engine.stopDiscovery();
        await alex.engine.startHosting();
        final again = await priya.find(alex);
        expect(again.sharedGroupIds, [
          seed.g,
        ], reason: 'a recently synced group is kept in the advert');
      });
    }
  });

  group('R2-01 probes: advert sizes with the widest names', () {
    // 4-byte emoji names, the most tokens, and the cut flag together.
    const wide =
        '\u{1F600}\u{1F601}\u{1F602}\u{1F603}\u{1F604}'
        '\u{1F605}\u{1F606}\u{1F607}\u{1F608}\u{1F609}';
    final name = wide * 5; // 50 runes, 200 bytes
    Future<AdvertiseInfo> advert(int groups) async {
      final keys = {
        for (var i = 0; i < groups; i++) groupIdOf(i + 1): groupKeyOf(i),
      };
      final t = DateTime.utc(2026, 11, 9, 12);
      return AdvertiseInfo(
        deviceId: 'aaaaaaaa-0000-7000-8000-000000000001',
        deviceName: name,
        groupTokens: await DiscoveryTokens.advertised(keys, t),
        advertId: 'abcdef01',
        tokenWindow: DiscoveryTokens.windowAt(t),
      );
    }

    for (final groups in const [23, 24, 25, 60, 96, 97, 300]) {
      test(
        '$groups groups: every advert fits, round-trips and flags a cut',
        () async {
          final a = await advert(groups);
          final n = NearbyEndpointName.of(a).encode();
          expect(utf8.encode(n).length, lessThanOrEqualTo(131));
          final np = NearbyEndpointName.tryParse(n)!;
          expect(np.groupTokens.length, groups.clamp(0, 24));
          expect(np.moreGroups, groups > 24);
          expect(np.groupTokens.toSet(), a.groupTokens.take(24).toSet());

          final b = BleInfo.of(a).encode();
          expect(b.length, lessThanOrEqualTo(512));
          final bp = BleInfo.tryParse(b)!;
          expect(
            bp.groupTokens.length,
            greaterThanOrEqualTo(groups.clamp(0, 57)),
          );
          expect(bp.moreGroups, bp.groupTokens.length < groups);
          expect(
            bp.groupTokens.toSet(),
            a.groupTokens.take(bp.groupTokens.length).toSet(),
            reason: 'BLE keeps the most important tokens',
          );

          final txt = MdnsAdvert.of(a, 47321).attributes;
          var total = 0;
          for (final e in txt.entries) {
            final len = utf8.encode('${e.key}=${e.value}').length;
            expect(len, lessThanOrEqualTo(255), reason: e.key);
            total += len + 1;
          }
          expect(total, lessThan(1300));
          final lp = MdnsSighting(
            name: 'Alex',
            addresses: const ['192.168.1.20'],
            port: 47321,
            attributes: txt,
          ).toPeer()!;
          expect(lp.groupTokens.length, groups.clamp(0, 240));
          expect(lp.moreGroups, groups > 240);
        },
      );
    }
  });
}
