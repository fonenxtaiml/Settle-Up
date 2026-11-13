// QA SYNC round 9: reverification of the SYNC-R8-01 fix (discovery keeps
// every sighting until its own withdrawal and shows the newest one per
// phone, so a goodbye of a stale old name no longer hides the live renamed
// service). The defect class is "a withdrawal of one key hides another key
// of the same phone that was never withdrawn"; it is probed on every
// transport that caches sightings by a platform key: LanTransport (mDNS
// service name) and NearbyTransport (Nearby endpoint id), at transport
// level and through the real DefaultSyncEngine Nearby list.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/nearby/nearby_api.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/nearby/nearby_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/bluetooth/support/bt_phone.dart';
import '../../sync/bluetooth/support/fake_nearby.dart';
import '../../sync/bluetooth/support/fake_permissions.dart';
import '../../sync/lan/support.dart';
import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';

/// An mDNS backend whose browse stream carries only what [deliver] sends.
final class _ScriptedMdns implements MdnsBackend {
  final List<StreamController<(String, MdnsSighting?)>> _browses = [];

  @override
  Future<void> advertise(MdnsAdvert advert) async {}
  @override
  Future<void> stopAdvertising() async {}

  @override
  Stream<(String, MdnsSighting?)> browse() {
    late StreamController<(String, MdnsSighting?)> ctl;
    ctl = StreamController(onCancel: () => _browses.remove(ctl));
    _browses.add(ctl);
    return ctl.stream;
  }

  void deliver((String, MdnsSighting?) event) {
    for (final b in _browses) {
      b.add(event);
    }
  }
}

(String, MdnsSighting?) _resolved(
  String name, {
  String id = 'abcd1234',
  String host = '10.0.0.2',
}) => (
  name,
  MdnsSighting(
    name: name,
    addresses: [host],
    port: 52741,
    attributes: {'v': '2', 'd': id, 't': ''},
  ),
);

(String, MdnsSighting?) _goodbye(String name) => (name, null);

/// Every ordering of [items].
List<List<T>> _permutations<T>(List<T> items) {
  if (items.length <= 1) return [List.of(items)];
  return [
    for (var i = 0; i < items.length; i++)
      for (final rest in _permutations([
        ...items.take(i),
        ...items.skip(i + 1),
      ]))
        [items[i], ...rest],
  ];
}

String _endpointName(String advertId, String device) => NearbyEndpointName(
  advertId: advertId,
  deviceName: device,
  groupTokens: const ['T001'],
).encode();

void main() {
  const round = Duration(milliseconds: 15);

  group('LanTransport, scripted mDNS: the SYNC-R8-01 class', () {
    late _ScriptedMdns mdns;
    late LanTransport t;

    setUp(() {
      mdns = _ScriptedMdns();
      t = LanTransport(
        port: 0,
        mdns: mdns,
        network: FakeLanNetwork(),
        rediscoverInterval: round,
        probeInterval: const Duration(hours: 1),
      );
    });
    tearDown(() => t.dispose());

    Future<Set<String>> shownAfter(List<(String, MdnsSighting?)> events) async {
      final seen = <DiscoveredPeer>[];
      final sub = t.discover().listen(seen.add);
      await Future<void>.delayed(Duration.zero);
      for (final e in events) {
        mdns.deliver(e);
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(round ~/ 2);
      seen.clear();
      await Future<void>.delayed(round * 4);
      await sub.cancel();
      return {for (final p in seen) p.name};
    }

    // Two missed renames: 'Pixel 8' -> 'Alex 2' -> "Alex's phone" (live).
    // A fresh browse replays the two stale names in any order around the
    // live one, then both stale records expire in either order. The live
    // service never had a goodbye, so it is what remains listed, and the
    // phone is listed (one row) at every step in between.
    test('two stale names resolved in any order around the live one, then '
        'expiring in any order: the live name is listed at the end and the '
        'phone is never missing in between', () async {
      const live = "Alex's phone";
      const stale = ['Pixel 8', 'Alex 2'];
      for (final order in _permutations([live, ...stale])) {
        for (final expiry in _permutations(stale)) {
          final events = [for (final n in order) _resolved(n)];
          for (var k = 1; k <= expiry.length; k++) {
            final upTo = [
              ...events,
              for (final n in expiry.take(k)) _goodbye(n),
            ];
            await t.dispose();
            mdns = _ScriptedMdns();
            t = LanTransport(
              port: 0,
              mdns: mdns,
              network: FakeLanNetwork(),
              rediscoverInterval: round,
              probeInterval: const Duration(hours: 1),
            );
            final shown = await shownAfter(upTo);
            expect(shown, hasLength(1), reason: 'order $order, $upTo');
            if (k == expiry.length) {
              expect(shown, {live}, reason: 'order $order, expiry $expiry');
            }
          }
        }
      }
    });

    test('the stale old record at the old address with the same advert id '
        '(the phone changed address): its expiry shows the live one', () async {
      expect(
        await shownAfter([
          _resolved("Alex's phone", host: '10.0.0.7'),
          _resolved('Pixel 8'),
          _goodbye('Pixel 8'),
        ]),
        {"Alex's phone"},
      );
    });

    test('a window change (new advert id) on the live name while the stale '
        'one is shown makes the live one newest again', () async {
      expect(
        await shownAfter([
          _resolved("Alex's phone"),
          _resolved('Pixel 8'),
          _resolved("Alex's phone", id: 'ffff0000'),
        ]),
        {"Alex's phone"},
      );
    });

    test(
      'a third phone is untouched by another phone\'s stale goodbye',
      () async {
        expect(
          await shownAfter([
            _resolved('Priya', id: 'cccc0000', host: '10.0.0.3'),
            _resolved("Alex's phone"),
            _resolved('Pixel 8'),
            _goodbye('Pixel 8'),
          ]),
          {"Alex's phone", 'Priya'},
        );
      },
    );

    test('goodbyes of every name leave nothing listed', () async {
      expect(
        await shownAfter([
          _resolved("Alex's phone"),
          _resolved('Pixel 8'),
          _goodbye('Pixel 8'),
          _goodbye("Alex's phone"),
        ]),
        isEmpty,
      );
    });
  });

  group('LanTransport through the engine: the stale goodbye keeps the phone '
      'in the Nearby list past nearbyTtl', () {
    test('resolved(live), resolved(stale), goodbye(stale): the live name '
        'is still listed after 3x nearbyTtl', () async {
      final mdns = _ScriptedMdns();
      final phone = await TestPhone.create('a', deviceName: 'Priya phone');
      final engine = DefaultSyncEngine(
        store: phone.ledger,
        transports: [
          LanTransport(
            port: 0,
            mdns: mdns,
            network: FakeLanNetwork(),
            rediscoverInterval: const Duration(milliseconds: 100),
            probeInterval: const Duration(hours: 1),
          ),
        ],
        timings: fastTimings,
        nearbyTtl: const Duration(milliseconds: 600),
      );
      addTearDown(() async {
        await engine.dispose();
        await phone.close();
      });
      await engine.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      mdns.deliver(_resolved("Alex's phone"));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      mdns.deliver(_resolved('Pixel 8'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      mdns.deliver(_goodbye('Pixel 8'));
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      final list = await engine.watchNearby().first;
      expect([for (final p in list) p.name], ["Alex's phone"]);
    });
  });

  // NearbyTransport keeps found endpoints in a map keyed by endpoint id and
  // re-emits them every rediscoverInterval, because Nearby reports an
  // endpoint found only once per discovery. Its SYNC-R6-01 fix still uses
  // the eviction rule SYNC-R8-01 fixed on LAN: a newer endpoint of the same
  // advert id removes the older one from the map. A stale endpoint found
  // after the live one (a restarted discovery answering from Nearby's
  // medium caches, or the old endpoint reported late over a slower medium)
  // therefore evicts the live endpoint, and the stale one's loss empties
  // the map: the phone vanishes although it still advertises.
  group('NearbyTransport: the SYNC-R8-01 class on Nearby endpoints', () {
    late FakeNearbyAir air;
    setUp(() => air = FakeNearbyAir());

    NearbyTransport transport(FakeNearbyApi api) {
      final t = NearbyTransport(
        permissions: grantedPermissions(),
        api: api,
        isAndroid: true,
        rediscoverInterval: round,
      );
      addTearDown(t.dispose);
      return t;
    }

    Future<Set<String>> shownAfter(
      NearbyTransport t,
      FakeNearbyApi api,
      List<NearbyEvent> events,
    ) async {
      final seen = <DiscoveredPeer>[];
      final sub = t.discover().listen(seen.add);
      await pumpUntil(() => api.discovering);
      for (final e in events) {
        api.deliver(e);
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(round ~/ 2);
      seen.clear();
      await Future<void>.delayed(round * 4);
      await sub.cancel();
      return {for (final p in seen) '${p.address}/${p.name}'};
    }

    test('control: old, new, old lost keeps the new endpoint', () async {
      final api = air.phone('A');
      final t = transport(api);
      expect(
        await shownAfter(t, api, [
          NearbyEndpointFound('E1', _endpointName('bbbbbbbb', 'Pixel 8')),
          NearbyEndpointFound('E2', _endpointName('bbbbbbbb', "Alex's phone")),
          NearbyEndpointLost('E1'),
        ]),
        {"E2/Alex's phone"},
      );
    });

    test(
      'SYNC-R8-01: new endpoint, stale old endpoint, then the old '
      'endpoint\'s loss: the still-advertised new endpoint stays listed',
      () async {
        final api = air.phone('A');
        final t = transport(api);
        expect(
          await shownAfter(t, api, [
            NearbyEndpointFound(
              'E2',
              _endpointName('bbbbbbbb', "Alex's phone"),
            ),
            NearbyEndpointFound('E1', _endpointName('bbbbbbbb', 'Pixel 8')),
            NearbyEndpointLost('E1'),
          ]),
          {"E2/Alex's phone"},
          reason: 'no loss was ever reported for E2',
        );
      },
    );

    test(
      'SYNC-R8-01: through the engine, the phone is gone from Nearby after '
      'nearbyTtl although E2 still advertises',
      () async {
        final api = air.phone('A');
        final phone = await TestPhone.create('a', deviceName: 'Priya phone');
        final engine = DefaultSyncEngine(
          store: phone.ledger,
          transports: [transport(api)],
          timings: fastTimings,
          nearbyTtl: const Duration(milliseconds: 600),
        );
        addTearDown(() async {
          await engine.dispose();
          await phone.close();
        });
        await engine.startDiscovery();
        await pumpUntil(() => api.discovering);
        api.deliver(
          NearbyEndpointFound('E2', _endpointName('bbbbbbbb', "Alex's phone")),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        api.deliver(
          NearbyEndpointFound('E1', _endpointName('bbbbbbbb', 'Pixel 8')),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        api.deliver(NearbyEndpointLost('E1'));
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        final list = await engine.watchNearby().first;
        expect(
          [for (final p in list) p.name],
          ["Alex's phone"],
          reason: 'E2 was never reported lost',
        );
      },
    );
  });
}
