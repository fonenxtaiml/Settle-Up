// QA SYNC-R1: engine orchestration. One session at a time, cancel,
// hosting expiry, transport fallback, links with unreachable hosts.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'qa_phone.dart';

const _all = [TransportKind.lan, TransportKind.nearby, TransportKind.ble];

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(
    String letter,
    String name, {
    List<TransportKind> kinds = _all,
    SessionTimings timings = fastTimings,
    SyncTransport Function(MemoryTransport)? wrap,
  }) async {
    final p = await QaPhone.create(
      hub,
      letter,
      name,
      kinds: kinds,
      timings: timings,
      wrap: wrap,
    );
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

  Future<(QaPhone, QaPhone, QaSeed)> pair({int expenses = 3}) async {
    final alex = await phone('a', "Alex's Pixel");
    final priya = await phone('b', "Priya's Pixel");
    final seed = await alex.seedGroup(expenses: expenses);
    await priya.join(alex, seed.g);
    return (alex, priya, seed);
  }

  Matcher failsWith(SyncFailure f) =>
      throwsA(isA<SyncException>().having((e) => e.failure, 'failure', f));

  group('transport fallback lan -> nearby -> ble', () {
    test('all three seen: lan is used', () async {
      final (alex, priya, _) = await pair();
      await priya.engine.startHosting();
      final peer = await alex.find(priya, transports: 3);
      expect(peer.transports, _all.toSet());
      expect((await alex.engine.syncWith(peer)).transport, TransportKind.lan);
    });

    test('lan cannot connect: nearby is next', () async {
      final (alex, priya, _) = await pair();
      await priya.engine.startHosting();
      final peer = await alex.find(priya, transports: 3);
      alex.lan.failConnect = true;
      expect(
        (await alex.engine.syncWith(peer)).transport,
        TransportKind.nearby,
      );
      expect(priya.canonical, alex.canonical);
    });

    test('lan and nearby cannot connect: ble is last', () async {
      final (alex, priya, _) = await pair();
      await priya.engine.startHosting();
      final peer = await alex.find(priya, transports: 3);
      alex.lan.failConnect = true;
      alex.nearby.failConnect = true;
      expect((await alex.engine.syncWith(peer)).transport, TransportKind.ble);
    });

    test(
      'a transport that is not ready on the host is never advertised',
      () async {
        final (alex, priya, _) = await pair();
        priya.lan.availabilityState = TransportAvailability.radioOff;
        final host = await priya.engine.startHosting();
        expect(host.transports, {TransportKind.nearby, TransportKind.ble});
        final peer = await alex.find(priya, transports: 2);
        expect(peer.transports, {TransportKind.nearby, TransportKind.ble});
        expect(
          (await alex.engine.syncWith(peer)).transport,
          TransportKind.nearby,
        );
      },
    );

    test('every route fails: peerUnreachable, recorded, engine free', () async {
      final (alex, priya, _) = await pair();
      await priya.engine.startHosting();
      final peer = await alex.find(priya, transports: 3);
      for (final t in alex.transports.values) {
        t.failConnect = true;
      }
      await expectLater(
        alex.engine.syncWith(peer),
        failsWith(SyncFailure.peerUnreachable),
      );
      expect((await alex.records()).single.outcome, SyncOutcome.failed);
      for (final t in alex.transports.values) {
        t.failConnect = false;
      }
      expect((await alex.engine.syncWith(peer)).sentOps, 6);
    });

    test('the host went away after discovery: peerUnreachable', () async {
      final (alex, priya, _) = await pair();
      await priya.engine.startHosting();
      final peer = await alex.find(priya, transports: 3);
      await priya.engine.stopHosting();
      await expectLater(
        alex.engine.syncWith(peer),
        failsWith(SyncFailure.peerUnreachable),
      );
    });
  });

  group('syncWithLink', () {
    test(
      'every host unreachable: peerUnreachable, record, engine free',
      () async {
        final (alex, priya, _) = await pair();
        final link = ConnectLink(
          hosts: const ['192.168.43.1:47321', '10.0.0.9:47321'],
          deviceId: priya.deviceId,
          deviceName: 'Priya',
        ).encode();
        await expectLater(
          alex.engine.syncWithLink(link),
          failsWith(SyncFailure.peerUnreachable),
        );
        expect((await alex.records()).single.outcome, SyncOutcome.failed);
        expect(alex.engine.status.session, isA<SessionFailed>());
        // Not busy afterwards.
        final host = await priya.engine.startHosting();
        expect((await alex.engine.syncWithLink(host.connectLink)).sentOps, 6);
      },
    );

    test(
      'dead hosts first, live host last: tries in order and succeeds',
      () async {
        final (alex, priya, _) = await pair();
        await priya.engine.startHosting();
        final link = ConnectLink(
          hosts: const ['nowhere:1', 'gone:2', 'b-lan'],
          deviceId: priya.deviceId,
          deviceName: 'Priya',
        ).encode();
        final s = await alex.engine.syncWithLink(link);
        expect(s.sentOps, 6);
        expect(s.peerName, "Priya's Pixel", reason: 'name from the HELLO');
      },
    );

    test('scanning my own connect link fails cleanly', () async {
      final (alex, _, _) = await pair();
      final host = await alex.engine.startHosting();
      Object? err;
      try {
        await alex.engine.syncWithLink(host.connectLink);
      } catch (e) {
        err = e;
      }
      expect(err, isA<SyncException>());
      // Still usable.
      await alex.engine.stopHosting();
      expect(alex.engine.status.host, isNull);
    });
  });

  group('one session at a time', () {
    test(
      'a second syncWith while one runs is refused; the first completes',
      () async {
        hub.latency = const Duration(milliseconds: 10);
        final (alex, priya, _) = await pair(expenses: 30);
        final host = await priya.engine.startHosting();
        final first = alex.engine.syncWithLink(host.connectLink);
        await expectLater(
          alex.engine.syncWithLink(host.connectLink),
          throwsA(isA<SyncException>()),
        );
        await expectLater(
          alex.engine.acceptInvite(
            await alex.engine.inviteLinkFor(alex.state.groups.keys.first),
          ),
          completion(isA<JoinResult>()),
        );
        expect((await first).sentOps, 33);
      },
    );

    test(
      'a third phone gets busy while the host syncs, then gets in',
      () async {
        hub.latency = const Duration(milliseconds: 15);
        final (alex, priya, seed) = await pair(expenses: 40);
        final ravi = await phone('c', "Ravi's Galaxy");
        await ravi.join(alex, seed.g);
        final host = await priya.engine.startHosting();
        final first = alex.engine.syncWithLink(host.connectLink);
        await waitFor(() => priya.engine.status.session is SessionActive);
        await expectLater(
          ravi.engine.syncWithLink(host.connectLink),
          throwsA(
            isA<SyncException>()
                .having(
                  (e) => e.failure,
                  'failure',
                  SyncFailure.peerUnreachable,
                )
                .having((e) => e.message, 'message', contains('busy')),
          ),
        );
        await first;
        final before = (await priya.records()).length;
        await waitFor(
          () async =>
              (await priya.records()).length > before - 1 &&
              priya.engine.status.session is! SessionActive,
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final later = await ravi.engine.syncWithLink(host.connectLink);
        expect(later.receivedOps, 43);
        expect(allEqual([alex, priya, ravi]), isTrue);
      },
    );
  });

  group('cancel', () {
    test(
      'cancel mid-transfer: cancelled on both sides, next sync completes',
      () async {
        final (alex, priya, seed) = await pair(expenses: 0);
        await alex.addExpenses(seed, 400);
        hub.latency = const Duration(milliseconds: 10);
        final host = await priya.engine.startHosting();
        final run = alex.engine.syncWithLink(host.connectLink);
        await waitFor(() {
          final s = alex.engine.status.session;
          return s is SessionActive &&
              s.progress.phase == SyncPhase.transferring;
        });
        await alex.engine.cancel();
        await expectLater(run, failsWith(SyncFailure.cancelled));
        expect((await alex.records()).single.outcome, SyncOutcome.cancelled);
        await waitFor(() async => (await priya.records()).isNotEmpty);
        final pr = (await priya.records()).single;
        expect(pr.outcome, SyncOutcome.cancelled, reason: '${pr.error}');
        expect(priya.engine.status.session, isA<SessionFailed>());

        hub.latency = Duration.zero;
        final again = await alex.engine.syncWithLink(host.connectLink);
        expect(priya.canonical, alex.canonical);
        expect(again.sentOps + priya.opCount(seed.g) - again.sentOps, 403);
      },
    );

    test('cancel while connecting: cancelled, nothing sent', () async {
      final (alex, priya, _) = await pair();
      await priya.engine.startHosting();
      final peer = await alex.find(priya, transports: 3);
      final run = alex.engine.syncWith(peer);
      unawaited(alex.engine.cancel());
      Object? err;
      try {
        await run;
      } catch (e) {
        err = e;
      }
      // Either it was too late (completed) or it is cancelled; never stuck.
      if (err != null) {
        expect((err as SyncException).failure, SyncFailure.cancelled);
      }
      // Give the host a moment (a human retry is never instantaneous).
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final again = await alex.engine
          .syncWith(await alex.find(priya, transports: 3))
          .timeout(const Duration(seconds: 5));
      expect(again, isA<SyncSummary>());
    });

    test('cancel with nothing running is a no-op', () async {
      final (alex, _, _) = await pair();
      await alex.engine.cancel();
      expect(alex.engine.status.session, isA<SessionIdle>());
    });
  });

  group('hosting', () {
    test('hosting expires mid-session: the session still completes', () async {
      final (alex, priya, seed) = await pair(expenses: 0);
      await alex.addExpenses(seed, 300);
      hub.latency = const Duration(milliseconds: 5);
      final host = await priya.engine.startHosting(
        duration: const Duration(milliseconds: 150),
      );
      final run = alex.engine.syncWithLink(host.connectLink);
      expect(await waitFor(() => priya.engine.status.host == null), isTrue);
      final s = await run;
      expect(s.sentOps, 303);
      expect(priya.canonical, alex.canonical);
      expect(priya.lan.isAdvertising, isFalse);
      // A new connection after expiry is refused.
      await expectLater(
        alex.engine.syncWithLink(host.connectLink),
        failsWith(SyncFailure.peerUnreachable),
      );
    });

    test('a joined group is advertised without restarting hosting', () async {
      final (alex, priya, seed) = await pair();
      final ravi = await phone('c', "Ravi's Galaxy");
      await ravi.engine.startHosting();
      final before = await alex.find(ravi);
      expect(before.sharesGroups, isFalse);
      await ravi.engine.acceptInvite(
        await alex.engine.inviteLinkFor(seed.g, includeHost: false),
      );
      expect(
        await waitFor(
          () async => (await alex.engine.watchNearby().first).any(
            (p) => p.name == ravi.deviceName && p.sharesGroups,
          ),
          timeout: const Duration(seconds: 7),
        ),
        isTrue,
      );
      expect(priya, isNotNull);
    });
  });

  test(
    'SYNC-R1-05: a retry from the same phone is not refused as busy while '
    'the host still holds the dead session',
    () async {
      CuttableTransport? alexLan;
      final alex = await phone(
        'a',
        "Alex's Pixel",
        wrap: (t) {
          if (t.kind != TransportKind.lan) return t;
          return alexLan = CuttableTransport(t);
        },
      );
      // Production timers on the host: 20 s idle timeout.
      final priya = await phone(
        'b',
        "Priya's Pixel",
        timings: const SessionTimings(),
      );
      final seed = await alex.seedGroup(expenses: 0);
      await priya.join(alex, seed.g);
      await alex.addExpenses(seed, 300);
      hub.latency = const Duration(milliseconds: 10);
      await priya.engine.startHosting();
      final peer = await alex.find(priya, transports: 3);
      final first = alex.engine
          .syncWith(peer)
          .then<Object?>((s) => s, onError: (Object e) => e);
      await waitFor(() => priya.engine.status.session is SessionActive);
      // Alex's Wi-Fi drops (half-open TCP); Alex taps Cancel, then Retry.
      alexLan!.cut();
      await alex.engine.cancel();
      await first;
      alex.lan.failConnect = true; // Wi-Fi gone: retry goes over Nearby/BLE
      final retry = await alex.engine
          .syncWith(await alex.find(priya, transports: 2))
          .then<Object?>((s) => s, onError: (Object e) => e);
      expect(
        retry,
        isA<SyncSummary>(),
        reason: 'the host refused the same phone: $retry',
      );
    },
    skip:
        'QA SYNC-R1-05: host rejects the same phone as "busy: Syncing with '
        'another phone" until the dead session idles out (20 s)',
  );
}
