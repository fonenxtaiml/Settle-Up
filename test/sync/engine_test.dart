import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'support/harness.dart';
import 'support/phone.dart';

final class TestClock implements SyncClock {
  DateTime value = DateTime.utc(2026, 11, 9, 12);
  @override
  DateTime now() => value;
}

/// One phone: the real Ledger plus an engine over LAN and BLE memory
/// transports.
final class Phone {
  Phone._(this.phone, this.lan, this.ble, this.engine, this.clock);

  static Future<Phone> create(
    MemoryTransportHub hub,
    String letter,
    String name, {
    TestClock? clock,
  }) async {
    final phone = await TestPhone.create(letter, deviceName: name);
    final lan = MemoryTransport(
      hub,
      kind: TransportKind.lan,
      address: '$letter-lan',
    );
    final ble = MemoryTransport(
      hub,
      kind: TransportKind.ble,
      address: '$letter-ble',
      maxFrameBytes: 16384,
    );
    final engine = DefaultSyncEngine(
      store: phone.ledger,
      transports: [lan, ble],
      clock: clock,
      timings: fastTimings,
    );
    final p = Phone._(phone, lan, ble, engine, clock);
    p._records = phone.ledger.watchSyncRecords().listen((r) => p.records = r);
    return p;
  }

  final TestPhone phone;
  final TestClock? clock;
  final MemoryTransport lan;
  final MemoryTransport ble;
  final DefaultSyncEngine engine;

  /// Sync history, newest first (kept current).
  List<SyncRecord> records = const [];
  late final StreamSubscription<List<SyncRecord>> _records;

  Future<void> dispose() async {
    await engine.dispose();
    await _records.cancel();
    await phone.close();
  }

  /// Discovers [other] once it is seen on [transports] transports.
  Future<NearbyPeer> find(Phone other, {int transports = 2}) async {
    if (!engine.status.discovering) await engine.startDiscovery();
    bool match(NearbyPeer p) =>
        p.name == other.phone.deviceName && p.transports.length == transports;
    final list = await engine
        .watchNearby()
        .firstWhere((l) => l.any(match))
        .timeout(const Duration(seconds: 2));
    return list.firstWhere(match);
  }
}

void main() {
  late MemoryTransportHub hub;
  late Phone alex, priya;
  late ({String g, String a, String b}) seed;

  setUp(() async {
    hub = MemoryTransportHub();
    alex = await Phone.create(hub, 'a', "Alex's Pixel");
    priya = await Phone.create(hub, 'b', "Priya's Pixel");
    seed = await alex.phone.seedGroup(expenses: 4);
    await priya.phone.join(alex.phone, seed.g);
  });

  tearDown(() async {
    await alex.dispose();
    await priya.dispose();
  });

  test('host, discover across transports, sync, record history', () async {
    final host = await priya.engine.startHosting();
    expect(host.transports, {TransportKind.lan, TransportKind.ble});
    expect(host.addresses, containsAll(['b-lan', 'b-ble']));
    final link = ConnectLink.tryParse(host.connectLink)!;
    expect(link.deviceId, priya.phone.deviceId);
    expect(priya.engine.status.host, isNotNull);
    expect(host.expiresAt.isAfter(DateTime.now()), isTrue);

    final peer = await alex.find(priya);
    expect(peer.transports.toList(), [TransportKind.lan, TransportKind.ble]);
    expect(peer.sharedGroupIds, [seed.g]);
    expect(peer.deviceIdPrefix, priya.phone.deviceId.substring(0, 8));
    expect(alex.engine.status.discovering, isTrue);

    final statuses = <SyncStatus>[];
    final sub = alex.engine.watchStatus().listen(statuses.add);
    final summary = await alex.engine.syncWith(peer);

    expect(summary.sentOps, 7);
    expect(summary.transport, TransportKind.lan);
    expect(summary.peerDeviceId, priya.phone.deviceId);
    expect(summary.groupIds, [seed.g]);
    expect(priya.phone.canonical, alex.phone.canonical);
    await eventually(() => alex.engine.status.session is SessionCompleted);
    expect(
      statuses.map((s) => s.session).whereType<SessionActive>(),
      isNotEmpty,
    );
    expect(
      statuses
          .map((s) => s.session)
          .whereType<SessionActive>()
          .first
          .progress
          .phase,
      SyncPhase.connecting,
    );
    await eventually(() => priya.records.isNotEmpty);
    expect((await alex.phone.records()).single.outcome, SyncOutcome.completed);
    expect((await priya.phone.records()).single.receivedOps, 7);
    expect(priya.engine.status.session, isA<SessionCompleted>());
    final history = await alex.engine.watchHistory().first;
    expect(history.single.peerName, "Priya's Pixel");
    await sub.cancel();

    await priya.engine.stopHosting();
    expect(priya.engine.status.host, isNull);
    expect(priya.lan.isAdvertising, isFalse);
    await alex.engine.stopDiscovery();
    expect(alex.engine.status.discovering, isFalse);
    expect(await alex.engine.watchNearby().first, isEmpty);
  });

  test('falls back to the next transport when one cannot connect', () async {
    await priya.engine.startHosting();
    final peer = await alex.find(priya);
    alex.lan.failConnect = true;

    final summary = await alex.engine.syncWith(peer);

    expect(summary.transport, TransportKind.ble);
    expect(priya.phone.canonical, alex.phone.canonical);
  });

  test('peerUnreachable when every transport fails', () async {
    await priya.engine.startHosting();
    final peer = await alex.find(priya);
    alex.lan.failConnect = true;
    alex.ble.failConnect = true;

    await expectLater(
      alex.engine.syncWith(peer),
      throwsA(
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.peerUnreachable,
        ),
      ),
    );
    expect(alex.engine.status.session, isA<SessionFailed>());
    expect((await alex.phone.records()).single.outcome, SyncOutcome.failed);
  });

  test('a peer without shared groups is reported as such', () async {
    final stranger = await Phone.create(hub, 'c', "Ravi's iPhone");
    await stranger.phone.seedGroup();
    await stranger.engine.startHosting();
    final peer = await alex.find(stranger);
    expect(peer.sharesGroups, isFalse);

    await expectLater(
      alex.engine.syncWith(peer),
      throwsA(
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.noSharedGroups,
        ),
      ),
    );
    await stranger.dispose();
  });

  test('busy: a second inbound connection is refused while syncing', () async {
    hub.latency = const Duration(milliseconds: 20);
    final ravi = await Phone.create(hub, 'c', "Ravi's iPhone");
    await ravi.phone.join(alex.phone, seed.g);
    await priya.engine.startHosting();
    final fromAlex = await alex.find(priya);
    final fromRavi = await ravi.find(priya);

    final first = alex.engine.syncWith(fromAlex);
    await eventually(() => priya.engine.status.session is SessionActive);
    final second = ravi.engine.syncWith(fromRavi);

    await expectLater(
      second,
      throwsA(
        isA<SyncException>()
            .having((e) => e.failure, 'failure', SyncFailure.peerUnreachable)
            .having((e) => e.message, 'message', contains('busy')),
      ),
    );
    expect((await first).sentOps, 7);
    // Once free, Ravi gets in.
    await eventually(() => priya.engine.status.session is SessionCompleted);
    final later = await ravi.engine.syncWith(fromRavi);
    expect(later.receivedOps, 7);
    await ravi.dispose();
  });

  test('one session at a time on the initiating side too', () async {
    hub.latency = const Duration(milliseconds: 10);
    await priya.engine.startHosting();
    final peer = await alex.find(priya);
    final first = alex.engine.syncWith(peer);
    await expectLater(
      alex.engine.syncWith(peer),
      throwsA(isA<SyncException>()),
    );
    await first;
  });

  test('live mode pushes a new local op to the peer within 1 s', () async {
    alex.engine.liveMode = true;
    priya.engine.liveMode = true;
    await priya.engine.startHosting();
    final peer = await alex.find(priya);

    final summary = await alex.engine.syncWith(peer); // resolves at LIVE
    expect(summary.sentOps, 7);
    expect(alex.engine.status.session, isA<SessionCompleted>());

    final sw = Stopwatch()..start();
    await alex.phone.addExpense(
      seed.g,
      payer: seed.a,
      owers: [seed.a, seed.b],
      total: 1234,
    );
    expect(await eventually(() => priya.phone.opCount(seed.g) == 8), isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    expect(priya.phone.canonical, alex.phone.canonical);

    // Leaving the Sync screen ends the session gracefully.
    alex.engine.liveMode = false;
    await eventually(() => alex.records.isNotEmpty);
    expect((await alex.phone.records()).single.outcome, SyncOutcome.completed);
    expect((await alex.phone.records()).single.sentOps, 8);
  });

  test('syncWithLink connects to the hosts in a connect link', () async {
    final host = await priya.engine.startHosting();
    final summary = await alex.engine.syncWithLink(host.connectLink);
    expect(summary.sentOps, 7);
    expect(summary.peerName, "Priya's Pixel");
  });

  test('syncWithLink tries hosts in order', () async {
    await priya.engine.startHosting();
    final link = ConnectLink(
      hosts: const ['nowhere:1', 'b-lan'],
      deviceId: priya.phone.deviceId,
      deviceName: 'Priya',
    ).encode();
    final summary = await alex.engine.syncWithLink(link);
    expect(summary.sentOps, 7);
  });

  test('bad links are invalidCode', () async {
    for (final bad in [
      'hello',
      'settleup://sync?v=9',
      'settleup://join?v=1',
      // Scanned garbage: percent escapes that are not UTF-8.
      'settleup://sync?v=1&h=%FF&d=x',
      'settleup://join?v=1&g=%C3&k=AA&n=x&c=y',
    ]) {
      await expectLater(
        alex.engine.syncWithLink(bad),
        throwsA(
          isA<SyncException>().having(
            (e) => e.failure,
            'failure',
            SyncFailure.invalidCode,
          ),
        ),
      );
      await expectLater(
        alex.engine.acceptInvite(bad),
        throwsA(
          isA<SyncException>().having(
            (e) => e.failure,
            'failure',
            SyncFailure.invalidCode,
          ),
        ),
      );
    }
  });

  test(
    'invite with a host: join, then the first sync brings the group',
    () async {
      final ravi = await Phone.create(hub, 'c', "Ravi's iPhone");
      final link = await alex.engine.inviteLinkFor(seed.g);
      final invite = InviteLink.tryParse(link)!;
      expect(invite.host, 'a-lan');
      expect(invite.groupName, 'Goa trip');
      expect(invite.currency, 'INR');
      expect(invite.deviceId, alex.phone.deviceId);
      expect(invite.fromName, "Alex's Pixel");
      expect(alex.engine.status.host, isNotNull);

      final result = await ravi.engine.acceptInvite(link);

      expect(result.groupId, seed.g);
      expect(result.alreadyMember, isFalse);
      expect(result.firstSync, isNotNull);
      expect(result.firstSync!.receivedOps, 7);
      expect(ravi.phone.canonical, alex.phone.canonical);
      // The group's create op arrived, so the join is no longer pending.
      expect(ravi.phone.snapshot.pendingJoins, isEmpty);

      final again = await ravi.engine.acceptInvite(link);
      expect(again.alreadyMember, isTrue);
      await ravi.dispose();
    },
  );

  test('invite without a reachable host still joins', () async {
    final ravi = await Phone.create(hub, 'c', "Ravi's iPhone");
    final link = await alex.engine.inviteLinkFor(seed.g, includeHost: false);
    expect(InviteLink.tryParse(link)!.host, isNull);
    expect(alex.engine.status.host, isNull);

    final result = await ravi.engine.acceptInvite(link);
    expect(result.firstSync, isNull);
    expect(await ravi.phone.ledger.groupKeys(), contains(seed.g));
    expect(ravi.phone.snapshot.pendingJoins[seed.g], isNotEmpty);
    await ravi.dispose();
  });

  test('cancel stops a running session', () async {
    for (var i = 0; i < 300; i++) {
      await alex.phone.addExpense(
        seed.g,
        payer: seed.a,
        owers: [seed.a, seed.b],
        total: 100 + i,
      );
    }
    hub.latency = const Duration(milliseconds: 15);
    await priya.engine.startHosting();
    final peer = await alex.find(priya);
    final run = alex.engine.syncWith(peer);
    await eventually(
      () =>
          alex.engine.status.session is SessionActive &&
          (alex.engine.status.session as SessionActive).progress.phase !=
              SyncPhase.connecting,
    );

    await alex.engine.cancel();

    await expectLater(
      run,
      throwsA(
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.cancelled,
        ),
      ),
    );
    final s = alex.engine.status.session as SessionFailed;
    expect(s.failure, SyncFailure.cancelled);
    expect((await alex.phone.records()).single.outcome, SyncOutcome.cancelled);
  });

  test('availability and permissions per transport', () async {
    alex.ble.availabilityState = TransportAvailability.needsPermission;
    expect(await alex.engine.availability(), {
      TransportKind.lan: TransportAvailability.ready,
      TransportKind.ble: TransportAvailability.needsPermission,
    });
    expect(await alex.engine.requestPermissions({TransportKind.ble}), {
      TransportKind.ble: TransportAvailability.ready,
    });
  });

  test(
    'hosting skips transports that are not ready, fails if none is',
    () async {
      priya.ble.availabilityState = TransportAvailability.radioOff;
      final host = await priya.engine.startHosting();
      expect(host.transports, {TransportKind.lan});
      await priya.engine.stopHosting();

      priya.lan.availabilityState = TransportAvailability.needsPermission;
      await expectLater(
        priya.engine.startHosting(),
        throwsA(
          isA<SyncException>().having(
            (e) => e.failure,
            'failure',
            SyncFailure.permissionDenied,
          ),
        ),
      );
    },
  );

  test('concurrent startHosting calls share one start', () async {
    final both = await Future.wait([
      priya.engine.startHosting(),
      priya.engine.startHosting(),
    ]);
    expect(identical(both[0], both[1]), isTrue);
    expect(identical(await priya.engine.startHosting(), both[0]), isTrue);
  });

  test('stopHosting while hosting is starting leaves nothing running',
      () async {
    final start = expectLater(
      priya.engine.startHosting(),
      throwsA(isA<SyncException>()
          .having((e) => e.failure, 'failure', SyncFailure.cancelled)),
    );
    await priya.engine.stopHosting();
    await start;

    expect(priya.lan.isAdvertising, isFalse);
    expect(priya.ble.isAdvertising, isFalse);
    expect(priya.engine.status.host, isNull);
    // A new start after the stop works.
    final again = await priya.engine.startHosting();
    expect(priya.engine.status.host, same(again));
    expect(priya.lan.isAdvertising, isTrue);
  });

  test('stopDiscovery while discovery is starting leaves nothing running',
      () async {
    await priya.engine.startHosting();
    final start = alex.engine.startDiscovery();
    await alex.engine.stopDiscovery();
    await start.then((_) {}, onError: (Object _) {});
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(alex.lan.activeDiscoveries + alex.ble.activeDiscoveries, 0);
    expect(alex.engine.status.discovering, isFalse);
    expect(await alex.engine.watchNearby().first, isEmpty);
  });

  test('dispose while hosting and discovery are starting', () async {
    final carol = await Phone.create(hub, 'c', 'Carol');
    final host =
        carol.engine.startHosting().then((_) {}, onError: (Object _) {});
    final scan =
        carol.engine.startDiscovery().then((_) {}, onError: (Object _) {});
    await carol.engine.dispose();
    await host;
    await scan;

    expect(carol.lan.isAdvertising, isFalse);
    expect(carol.lan.activeDiscoveries + carol.ble.activeDiscoveries, 0);
    await carol.phone.close();
  });

  test('hosting expires on its own', () async {
    await priya.engine.startHosting(
      duration: const Duration(milliseconds: 100),
    );
    expect(await eventually(() => priya.engine.status.host == null), isTrue);
    expect(priya.lan.isAdvertising, isFalse);
  });

  test('a peer not seen for 15 s is dropped', () async {
    final clock = TestClock();
    final carol = await Phone.create(hub, 'c', 'Carol', clock: clock);
    carol.lan.rediscoverInterval = const Duration(hours: 1);
    carol.ble.rediscoverInterval = const Duration(hours: 1);
    await priya.engine.startHosting();
    await carol.find(priya);

    clock.value = clock.value.add(const Duration(seconds: 16));
    final empty = await carol.engine
        .watchNearby()
        .firstWhere((l) => l.isEmpty)
        .timeout(const Duration(seconds: 3));
    expect(empty, isEmpty);
    await carol.dispose();
  });

  test('watchStatus and watchNearby emit the current value first', () async {
    expect(await alex.engine.watchStatus().first, same(alex.engine.status));
    expect(await alex.engine.watchNearby().first, isEmpty);
  });
}
