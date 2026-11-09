import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'support/harness.dart';
import 'support/test_ledger.dart';

/// A store that is also the LedgerRepository, like the real Ledger, so the
/// engine can read group names for invites.
final class RepoLedger extends TestLedger implements LedgerRepository {
  RepoLedger(super.localDeviceId, {super.localDeviceName});

  @override
  LedgerSnapshot get current => LedgerSnapshot(
        state: state,
        ops: const [],
        pendingJoins: pendingJoins,
        unsharedOpIds: const {},
        unsharedCounts: const {},
        localDeviceId: localDeviceId,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class TestClock implements SyncClock {
  DateTime value = DateTime.utc(2026, 11, 9, 12);
  @override
  DateTime now() => value;
}

/// One phone: a store plus an engine over LAN and BLE memory transports.
final class Phone {
  Phone(MemoryTransportHub hub, String letter, String name, {this.clock})
      : store = RepoLedger(deviceIdOf(letter), localDeviceName: name) {
    lan = MemoryTransport(hub, kind: TransportKind.lan, address: '$letter-lan');
    ble = MemoryTransport(hub,
        kind: TransportKind.ble, address: '$letter-ble', maxFrameBytes: 16384);
    engine = DefaultSyncEngine(
      store: store,
      transports: [lan, ble],
      clock: clock,
      timings: fastTimings,
    );
  }

  final TestLedger store;
  final TestClock? clock;
  late final MemoryTransport lan;
  late final MemoryTransport ble;
  late final DefaultSyncEngine engine;

  /// Discovers [other] once it is seen on [transports] transports.
  Future<NearbyPeer> find(Phone other, {int transports = 2}) async {
    if (!engine.status.discovering) await engine.startDiscovery();
    bool match(NearbyPeer p) =>
        p.name == other.store.localDeviceName &&
        p.transports.length == transports;
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
    alex = Phone(hub, 'a', "Alex's Pixel");
    priya = Phone(hub, 'b', "Priya's Pixel");
    seed = await seedGroup(alex.store, expenses: 4);
    await priya.store.registerJoinedGroup(
        seed.g, groupKeyOf(1), 'Goa trip');
  });

  tearDown(() async {
    await alex.engine.dispose();
    await priya.engine.dispose();
  });

  test('host, discover across transports, sync, record history', () async {
    final host = await priya.engine.startHosting();
    expect(host.transports, {TransportKind.lan, TransportKind.ble});
    expect(host.addresses, containsAll(['b-lan', 'b-ble']));
    final link = ConnectLink.tryParse(host.connectLink)!;
    expect(link.deviceId, priya.store.localDeviceId);
    expect(priya.engine.status.host, isNotNull);
    expect(host.expiresAt.isAfter(DateTime.now()), isTrue);

    final peer = await alex.find(priya);
    expect(peer.transports.toList(), [TransportKind.lan, TransportKind.ble]);
    expect(peer.sharedGroupIds, [seed.g]);
    expect(peer.deviceIdPrefix, priya.store.localDeviceId.substring(0, 8));
    expect(alex.engine.status.discovering, isTrue);

    final statuses = <SyncStatus>[];
    final sub = alex.engine.watchStatus().listen(statuses.add);
    final summary = await alex.engine.syncWith(peer);

    expect(summary.sentOps, 7);
    expect(summary.transport, TransportKind.lan);
    expect(summary.peerDeviceId, priya.store.localDeviceId);
    expect(summary.groupIds, [seed.g]);
    expect(priya.store.canonical, alex.store.canonical);
    await eventually(() => alex.engine.status.session is SessionCompleted);
    expect(statuses.map((s) => s.session).whereType<SessionActive>(),
        isNotEmpty);
    expect(
      statuses
          .map((s) => s.session)
          .whereType<SessionActive>()
          .first
          .progress
          .phase,
      SyncPhase.connecting,
    );
    await eventually(() => priya.store.records.isNotEmpty);
    expect(alex.store.records.single.outcome, SyncOutcome.completed);
    expect(priya.store.records.single.receivedOps, 7);
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
    expect(priya.store.canonical, alex.store.canonical);
  });

  test('peerUnreachable when every transport fails', () async {
    await priya.engine.startHosting();
    final peer = await alex.find(priya);
    alex.lan.failConnect = true;
    alex.ble.failConnect = true;

    await expectLater(
      alex.engine.syncWith(peer),
      throwsA(isA<SyncException>()
          .having((e) => e.failure, 'failure', SyncFailure.peerUnreachable)),
    );
    expect(alex.engine.status.session, isA<SessionFailed>());
    expect(alex.store.records.single.outcome, SyncOutcome.failed);
  });

  test('a peer without shared groups is reported as such', () async {
    final stranger = Phone(hub, 'c', "Ravi's iPhone");
    await seedGroup(stranger.store, group: 5);
    await stranger.engine.startHosting();
    final peer = await alex.find(stranger);
    expect(peer.sharesGroups, isFalse);

    await expectLater(
      alex.engine.syncWith(peer),
      throwsA(isA<SyncException>()
          .having((e) => e.failure, 'failure', SyncFailure.noSharedGroups)),
    );
    await stranger.engine.dispose();
  });

  test('busy: a second inbound connection is refused while syncing',
      () async {
    hub.latency = const Duration(milliseconds: 20);
    final ravi = Phone(hub, 'c', "Ravi's iPhone");
    await ravi.store.registerJoinedGroup(seed.g, groupKeyOf(1), 'Goa trip');
    await priya.engine.startHosting();
    final fromAlex = await alex.find(priya);
    final fromRavi = await ravi.find(priya);

    final first = alex.engine.syncWith(fromAlex);
    await eventually(() => priya.engine.status.session is SessionActive);
    final second = ravi.engine.syncWith(fromRavi);

    await expectLater(
      second,
      throwsA(isA<SyncException>()
          .having((e) => e.failure, 'failure', SyncFailure.peerUnreachable)
          .having((e) => e.message, 'message', contains('busy'))),
    );
    expect((await first).sentOps, 7);
    // Once free, Ravi gets in.
    await eventually(() => priya.engine.status.session is SessionCompleted);
    final later = await ravi.engine.syncWith(fromRavi);
    expect(later.receivedOps, 7);
    await ravi.engine.dispose();
  });

  test('one session at a time on the initiating side too', () async {
    hub.latency = const Duration(milliseconds: 10);
    await priya.engine.startHosting();
    final peer = await alex.find(priya);
    final first = alex.engine.syncWith(peer);
    await expectLater(alex.engine.syncWith(peer),
        throwsA(isA<SyncException>()));
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
    await alex.store.authorExpense(seed.g,
        payer: seed.a, owers: [seed.a, seed.b], total: 1234);
    expect(await eventually(() => priya.store.opCount(seed.g) == 8), isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    expect(priya.store.canonical, alex.store.canonical);

    // Leaving the Sync screen ends the session gracefully.
    alex.engine.liveMode = false;
    await eventually(() => alex.store.records.isNotEmpty);
    expect(alex.store.records.single.outcome, SyncOutcome.completed);
    expect(alex.store.records.single.sentOps, 8);
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
      deviceId: priya.store.localDeviceId,
      deviceName: 'Priya',
    ).encode();
    final summary = await alex.engine.syncWithLink(link);
    expect(summary.sentOps, 7);
  });

  test('bad links are invalidCode', () async {
    for (final bad in ['hello', 'settleup://sync?v=9', 'settleup://join?v=1']) {
      await expectLater(
        alex.engine.syncWithLink(bad),
        throwsA(isA<SyncException>()
            .having((e) => e.failure, 'failure', SyncFailure.invalidCode)),
      );
      await expectLater(
        alex.engine.acceptInvite(bad),
        throwsA(isA<SyncException>()
            .having((e) => e.failure, 'failure', SyncFailure.invalidCode)),
      );
    }
  });

  test('invite with a host: join, then the first sync brings the group',
      () async {
    final ravi = Phone(hub, 'c', "Ravi's iPhone");
    final link = await alex.engine.inviteLinkFor(seed.g);
    final invite = InviteLink.tryParse(link)!;
    expect(invite.host, 'a-lan');
    expect(invite.groupName, 'Goa trip');
    expect(invite.currency, 'INR');
    expect(invite.deviceId, alex.store.localDeviceId);
    expect(invite.fromName, "Alex's Pixel");
    expect(alex.engine.status.host, isNotNull);

    final result = await ravi.engine.acceptInvite(link);

    expect(result.groupId, seed.g);
    expect(result.alreadyMember, isFalse);
    expect(result.firstSync, isNotNull);
    expect(result.firstSync!.receivedOps, 7);
    expect(ravi.store.canonical, alex.store.canonical);

    final again = await ravi.engine.acceptInvite(link);
    expect(again.alreadyMember, isTrue);
    await ravi.engine.dispose();
  });

  test('invite without a reachable host still joins', () async {
    final ravi = Phone(hub, 'c', "Ravi's iPhone");
    final link = await alex.engine.inviteLinkFor(seed.g, includeHost: false);
    expect(InviteLink.tryParse(link)!.host, isNull);
    expect(alex.engine.status.host, isNull);

    final result = await ravi.engine.acceptInvite(link);
    expect(result.firstSync, isNull);
    expect(await ravi.store.groupKeys(), contains(seed.g));
    expect(ravi.store.pendingJoins[seed.g], isNotEmpty);
    await ravi.engine.dispose();
  });

  test('cancel stops a running session', () async {
    for (var i = 0; i < 300; i++) {
      await alex.store.authorExpense(seed.g,
          payer: seed.a, owers: [seed.a, seed.b], total: 100 + i);
    }
    hub.latency = const Duration(milliseconds: 15);
    await priya.engine.startHosting();
    final peer = await alex.find(priya);
    final run = alex.engine.syncWith(peer);
    await eventually(() =>
        alex.engine.status.session is SessionActive &&
        (alex.engine.status.session as SessionActive).progress.phase !=
            SyncPhase.connecting);

    await alex.engine.cancel();

    await expectLater(
      run,
      throwsA(isA<SyncException>()
          .having((e) => e.failure, 'failure', SyncFailure.cancelled)),
    );
    final s = alex.engine.status.session as SessionFailed;
    expect(s.failure, SyncFailure.cancelled);
    expect(alex.store.records.single.outcome, SyncOutcome.cancelled);
  });

  test('availability and permissions per transport', () async {
    alex.ble.availabilityState = TransportAvailability.needsPermission;
    expect(await alex.engine.availability(), {
      TransportKind.lan: TransportAvailability.ready,
      TransportKind.ble: TransportAvailability.needsPermission,
    });
    expect(await alex.engine.requestPermissions({TransportKind.ble}),
        {TransportKind.ble: TransportAvailability.ready});
  });

  test('hosting skips transports that are not ready, fails if none is',
      () async {
    priya.ble.availabilityState = TransportAvailability.radioOff;
    final host = await priya.engine.startHosting();
    expect(host.transports, {TransportKind.lan});
    await priya.engine.stopHosting();

    priya.lan.availabilityState = TransportAvailability.needsPermission;
    await expectLater(
      priya.engine.startHosting(),
      throwsA(isA<SyncException>()
          .having((e) => e.failure, 'failure', SyncFailure.permissionDenied)),
    );
  });

  test('hosting expires on its own', () async {
    await priya.engine.startHosting(
        duration: const Duration(milliseconds: 100));
    expect(await eventually(() => priya.engine.status.host == null), isTrue);
    expect(priya.lan.isAdvertising, isFalse);
  });

  test('a peer not seen for 15 s is dropped', () async {
    final clock = TestClock();
    final carol = Phone(hub, 'c', 'Carol', clock: clock);
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
    await carol.engine.dispose();
  });

  test('watchStatus and watchNearby emit the current value first', () async {
    expect(await alex.engine.watchStatus().first, same(alex.engine.status));
    expect(await alex.engine.watchNearby().first, isEmpty);
  });
}
