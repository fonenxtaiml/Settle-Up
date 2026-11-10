// NearbyTransport.discover() keeps every endpoint that was found and not
// yet lost, and shows only the newest one per advertiser (SYNC-R6-01). A
// loss withdraws only its own endpoint: an older endpoint of the same
// phone that was never lost is shown again (SYNC-R8-01). Nearby reports an
// endpoint found once per discovery, so a hidden endpoint that was dropped
// instead would never come back while the phone still advertises.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/sync/transport/nearby/nearby_api.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/nearby/nearby_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'support/bt_phone.dart';
import 'support/fake_nearby.dart';
import 'support/fake_permissions.dart';

const Duration _round = Duration(milliseconds: 15);

String _name(String advertId, String device) => NearbyEndpointName(
  advertId: advertId,
  deviceName: device,
  groupTokens: const ['T001'],
).encode();

NearbyEvent found(String endpoint, String advertId, String device) =>
    NearbyEndpointFound(endpoint, _name(advertId, device));

NearbyEvent lost(String endpoint) => NearbyEndpointLost(endpoint);

void main() {
  late FakeNearbyApi api;
  late NearbyTransport t;

  setUp(() {
    api = FakeNearbyAir().phone('A');
    t = NearbyTransport(
      permissions: grantedPermissions(),
      api: api,
      isAndroid: true,
      rediscoverInterval: _round,
    );
  });

  tearDown(() => t.dispose());

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

  group('SYNC-R8-01: a loss withdraws its own endpoint only', () {
    test('a stale old endpoint found after the live one hides it until the '
        'stale one is lost, then the live one is listed again', () async {
      expect(
        await shownAfter([
          found('E2', 'bbbbbbbb', "Alex's phone"),
          found('E1', 'bbbbbbbb', 'Pixel 8'),
        ]),
        {'E1/Pixel 8'},
      );
      expect(
        await shownAfter([
          found('E2', 'bbbbbbbb', "Alex's phone"),
          found('E1', 'bbbbbbbb', 'Pixel 8'),
          lost('E1'),
        ]),
        {"E2/Alex's phone"},
      );
    });

    test('the live endpoint is emitted again at once on the stale one\'s '
        'loss, not only at the next re-emit', () async {
      await t.dispose();
      t = NearbyTransport(
        permissions: grantedPermissions(),
        api: api,
        isAndroid: true,
        rediscoverInterval: const Duration(hours: 1),
      );
      final seen = <String>[];
      final sub = t.discover().listen(
        (p) => seen.add('${p.address}/${p.name}'),
      );
      await pumpUntil(() => api.discovering);
      api.deliver(found('E2', 'bbbbbbbb', "Alex's phone"));
      api.deliver(found('E1', 'bbbbbbbb', 'Pixel 8'));
      await Future<void>.delayed(Duration.zero);
      seen.clear();
      api.deliver(lost('E1'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, ["E2/Alex's phone"]);
      await sub.cancel();
    });

    test('a late loss of the old endpoint keeps the new one', () async {
      expect(
        await shownAfter([
          found('E1', 'bbbbbbbb', 'Pixel 8'),
          found('E2', 'bbbbbbbb', "Alex's phone"),
          lost('E1'),
        ]),
        {"E2/Alex's phone"},
      );
    });

    test('a loss of the newest endpoint shows the older one that was never '
        'lost', () async {
      expect(
        await shownAfter([
          found('E1', 'bbbbbbbb', 'Pixel 8'),
          found('E2', 'bbbbbbbb', "Alex's phone"),
          lost('E2'),
        ]),
        {'E1/Pixel 8'},
      );
    });

    test('both lost: nothing is listed', () async {
      expect(
        await shownAfter([
          found('E2', 'bbbbbbbb', "Alex's phone"),
          found('E1', 'bbbbbbbb', 'Pixel 8'),
          lost('E1'),
          lost('E2'),
        ]),
        isEmpty,
      );
    });

    test('a loss of an unknown endpoint changes nothing', () async {
      expect(
        await shownAfter([found('E2', 'bbbbbbbb', "Alex's phone"), lost('E9')]),
        {"E2/Alex's phone"},
      );
    });

    test('another phone is untouched by these losses', () async {
      expect(
        await shownAfter([
          found('E3', 'cccccccc', 'Sam'),
          found('E2', 'bbbbbbbb', "Alex's phone"),
          found('E1', 'bbbbbbbb', 'Pixel 8'),
          lost('E1'),
        ]),
        {"E2/Alex's phone", 'E3/Sam'},
      );
    });

    test('a late listener gets only the visible endpoints', () async {
      final first = t.discover().listen((_) {});
      await pumpUntil(() => api.discovering);
      api.deliver(found('E2', 'bbbbbbbb', "Alex's phone"));
      api.deliver(found('E1', 'bbbbbbbb', 'Pixel 8'));
      await Future<void>.delayed(Duration.zero);
      final seen = <String>[];
      final second = t.discover().listen(
        (p) => seen.add('${p.address}/${p.name}'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.first, 'E1/Pixel 8');
      expect(seen, isNot(contains("E2/Alex's phone")));
      await second.cancel();
      await first.cancel();
    });

    test('stopping discovery forgets hidden endpoints too', () async {
      final sub = t.discover().listen((_) {});
      await pumpUntil(() => api.discovering);
      api.deliver(found('E2', 'bbbbbbbb', "Alex's phone"));
      api.deliver(found('E1', 'bbbbbbbb', 'Pixel 8'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await pumpUntil(() => !api.discovering);
      // A new discovery: E1's loss must not bring back E2 from the last one.
      expect(
        await shownAfter([found('E1', 'bbbbbbbb', 'Pixel 8'), lost('E1')]),
        isEmpty,
      );
    });
  });

  test('seeded random found/lost sequences: one row per phone, and each row '
      'is that phone\'s newest endpoint that was never lost', () async {
    const endpoints = ['E1', 'E2', 'E3', 'E4', 'E5'];
    const ids = ['aaaa0001', 'aaaa0002', 'aaaa0003'];
    const names = ['Pixel 8', "Alex's phone", 'Priya', 'Sam'];
    for (var seed = 0; seed < 40; seed++) {
      final rng = Random(seed);
      final events = <NearbyEvent>[];
      // Reference model: endpoint -> (advert id, name), in found order.
      final cached = <String, (String, String)>{};
      for (var i = 0, n = 1 + rng.nextInt(12); i < n; i++) {
        final e = endpoints[rng.nextInt(endpoints.length)];
        if (rng.nextInt(3) == 0) {
          events.add(lost(e));
          cached.remove(e);
          continue;
        }
        final id = ids[rng.nextInt(ids.length)];
        final name = names[rng.nextInt(names.length)];
        events.add(found(e, id, name));
        cached.remove(e);
        cached[e] = (id, name);
      }
      final order = cached.entries.toList();
      final live = {
        for (var j = 0; j < order.length; j++)
          if (!order.skip(j + 1).any((o) => o.value.$1 == order[j].value.$1))
            '${order[j].key}/${order[j].value.$2}',
      };

      await t.dispose();
      api = FakeNearbyAir().phone('A');
      t = NearbyTransport(
        permissions: grantedPermissions(),
        api: api,
        isAndroid: true,
        rediscoverInterval: _round,
      );
      expect(await shownAfter(events), live, reason: 'seed $seed: $events');
    }
  });
}
