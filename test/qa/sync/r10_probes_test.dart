// QA SYNC round 10: reverification of the SYNC-R8-01 fix on Nearby
// (NearbyTransport now keeps found endpoints in the shared SightingCache:
// the newest endpoint per phone is shown, older ones stay hidden until
// their own loss, and a loss shows the next newest one again). The defect
// class is "a withdrawal of one platform key hides another key of the same
// phone that was never withdrawn". It is probed here over every
// interleaving of finds and losses of two stale endpoints around the live
// one, at transport level and through the real DefaultSyncEngine list.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/transport/nearby/nearby_api.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/nearby/nearby_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/bluetooth/support/bt_phone.dart';
import '../../sync/bluetooth/support/fake_nearby.dart';
import '../../sync/bluetooth/support/fake_permissions.dart';
import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';

const Duration _round = Duration(milliseconds: 15);

String _name(String advertId, String device) => NearbyEndpointName(
  advertId: advertId,
  deviceName: device,
  groupTokens: const ['T001'],
).encode();

/// Alex's phone: two stale endpoints of earlier names and the live one.
const _alex = 'bbbbbbbb';
const _devices = {'E0': 'Pixel 8', 'E1': 'Alex 2', 'E2': "Alex's phone"};

NearbyEvent _found(String e) =>
    NearbyEndpointFound(e, _name(_alex, _devices[e]!));
NearbyEvent _lost(String e) => NearbyEndpointLost(e);

/// Every sequence of found(E0), found(E1), found(E2), lost(E0), lost(E1)
/// in which each loss comes after its own find. E2 is never lost.
List<List<(bool, String)>> _interleavings() {
  final out = <List<(bool, String)>>[];
  void go(List<(bool, String)> acc, Set<String> foundSet, Set<String> lostSet) {
    if (acc.length == 5) {
      out.add(List.of(acc));
      return;
    }
    for (final e in ['E0', 'E1', 'E2']) {
      if (!foundSet.contains(e)) {
        go([...acc, (true, e)], {...foundSet, e}, lostSet);
      }
    }
    for (final e in ['E0', 'E1']) {
      if (foundSet.contains(e) && !lostSet.contains(e)) {
        go([...acc, (false, e)], foundSet, {...lostSet, e});
      }
    }
  }

  go([], {}, {});
  return out;
}

void main() {
  late FakeNearbyApi api;
  late NearbyTransport t;

  NearbyTransport fresh() {
    api = FakeNearbyAir().phone('A');
    return NearbyTransport(
      permissions: grantedPermissions(),
      api: api,
      isAndroid: true,
      rediscoverInterval: _round,
    );
  }

  /// Delivers [events] to a fresh discovery and returns what it re-emits
  /// afterwards, as 'endpoint/name'.
  Future<Set<String>> shownAfter(List<NearbyEvent> events) async {
    final seen = <DiscoveredPeer>[];
    final sub = t.discover().listen(seen.add);
    await pumpUntil(() => api.discovering);
    for (final e in events) {
      api.deliver(e);
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(_round ~/ 2);
    seen.clear();
    await Future<void>.delayed(_round * 4);
    await sub.cancel();
    return {for (final p in seen) '${p.address}/${p.name}'};
  }

  group('NearbyTransport: every interleaving of two stale endpoints around '
      'the live one', () {
    final cases = _interleavings();

    test('there are 30 interleavings', () => expect(cases, hasLength(30)));

    test('after every prefix the phone has exactly one row, it is the newest '
        'endpoint not yet lost, and a third phone is untouched', () async {
      for (final seq in cases) {
        for (var n = 1; n <= seq.length; n++) {
          final prefix = seq.take(n).toList();
          // Reference model: endpoints found and not lost, in found order.
          final live = <String>[];
          for (final (isFound, e) in prefix) {
            live.remove(e);
            if (isFound) live.add(e);
          }
          final expected = {
            'E9/Sam',
            if (live.isNotEmpty) '${live.last}/${_devices[live.last]}',
          };
          t = fresh();
          final shown = await shownAfter([
            NearbyEndpointFound('E9', _name('cccccccc', 'Sam')),
            for (final (isFound, e) in prefix) isFound ? _found(e) : _lost(e),
          ]);
          await t.dispose();
          expect(shown, expected, reason: '$prefix');
        }
      }
    });
  });

  group('through the engine (nearbyTtl 600 ms)', () {
    Future<(DefaultSyncEngine, FakeNearbyApi)> engine() async {
      final a = FakeNearbyAir().phone('A');
      final tr = NearbyTransport(
        permissions: grantedPermissions(),
        api: a,
        isAndroid: true,
        rediscoverInterval: _round,
      );
      final phone = await TestPhone.create('a', deviceName: 'Priya phone');
      final e = DefaultSyncEngine(
        store: phone.ledger,
        transports: [tr],
        timings: fastTimings,
        nearbyTtl: const Duration(milliseconds: 600),
      );
      addTearDown(() async {
        await e.dispose();
        await tr.dispose();
        await phone.close();
      });
      await e.startDiscovery();
      await pumpUntil(() => a.discovering);
      return (e, a);
    }

    Future<List<String>> names(DefaultSyncEngine e) async => [
      for (final p in await e.watchNearby().first) p.name,
    ];

    test(
      'live, two stale endpoints, their losses in reverse order: one row '
      'at every step, and the live name stays listed after 3x nearbyTtl',
      () async {
        final (e, a) = await engine();
        final keys = <String>{};
        Future<void> step(NearbyEvent ev) async {
          a.deliver(ev);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          final list = await e.watchNearby().first;
          expect(list, hasLength(1), reason: 'after $ev');
          keys.add(list.single.key);
        }

        await step(_found('E2'));
        await step(_found('E1'));
        await step(_found('E0'));
        await step(_lost('E1'));
        await step(_lost('E0'));
        expect(keys, hasLength(1), reason: 'the row keeps its key');
        await Future<void>.delayed(const Duration(milliseconds: 1800));
        expect(await names(e), ["Alex's phone"]);
      },
    );

    test('control: after the live endpoint is lost and then the stale one, '
        'the phone leaves the list', () async {
      final (e, a) = await engine();
      a.deliver(_found('E1'));
      a.deliver(_found('E2'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      a.deliver(_lost('E2'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      a.deliver(_lost('E1'));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(await names(e), isEmpty);
    });

    test('a restarted discovery does not bring back a stale endpoint from '
        'the previous run', () async {
      final (e, a) = await engine();
      a.deliver(_found('E2'));
      a.deliver(_found('E1'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await e.stopDiscovery();
      await pumpUntil(() => !a.discovering);
      await e.startDiscovery();
      await pumpUntil(() => a.discovering);
      a.deliver(_found('E2'));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(await names(e), ["Alex's phone"]);
    });
  });
}
