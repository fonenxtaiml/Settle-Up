import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/nearby_registry.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'support/rebuilding_registry.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 9, 12);
  late NearbyRegistry r;

  setUp(() {
    r = NearbyRegistry(selfAdvertIds: {'mememe00'})
      ..tokenIndex = {'tok-g1': 'g1', 'tok-g2': 'g2'};
  });

  DiscoveredPeer peer(
    TransportKind kind,
    String address, {
    String? prefix,
    String name = 'Priya',
    Set<String> tokens = const {},
  }) =>
      DiscoveredPeer(
        kind: kind,
        address: address,
        name: name,
        advertId: prefix,
        groupTokens: tokens,
      );

  test('merges transports by advert id, best transport first', () {
    expect(r.update(peer(TransportKind.ble, 'uuid-1', prefix: 'aaaa0000',
        tokens: {'tok-g2'}), t0), isTrue);
    expect(r.update(peer(TransportKind.lan, '10.0.0.2:52741',
        prefix: 'aaaa0000', tokens: {'tok-g1', 'nope'}), t0), isTrue);
    final p = r.peers.single;
    expect(p.key, 'aaaa0000');
    expect(p.transports.toList(), [TransportKind.lan, TransportKind.ble]);
    expect(p.sharedGroupIds, ['g1', 'g2']);
    expect(p.sharesGroups, isTrue);
    expect(r.routesFor('aaaa0000').map((d) => d.kind),
        [TransportKind.lan, TransportKind.ble]);
  });

  test('peers without an advert id are keyed by kind and address', () {
    r.update(peer(TransportKind.lan, '192.168.43.1:52741',
        name: 'Phone sharing its hotspot'), t0);
    r.update(peer(TransportKind.lan, '10.0.0.9:52741', name: 'Other'), t0);
    expect(r.peers.map((p) => p.key).toSet(),
        {'lan|192.168.43.1:52741', 'lan|10.0.0.9:52741'});
    expect(r.peers.every((p) => !p.sharesGroups), isTrue);
  });

  test('a route that later learns its advert id moves to that peer', () {
    r.update(peer(TransportKind.lan, '10.0.0.2:1'), t0);
    r.update(peer(TransportKind.ble, 'u', prefix: 'aaaa0000'), t0);
    r.update(peer(TransportKind.lan, '10.0.0.2:1', prefix: 'aaaa0000'), t0);
    expect(r.peers.single.transports,
        {TransportKind.lan, TransportKind.ble});
  });

  test('never lists this phone', () {
    expect(r.update(peer(TransportKind.lan, 'x', prefix: 'mememe00'), t0),
        isFalse);
    expect(r.peers, isEmpty);
  });

  test('unchanged sightings do not count as changes', () {
    final p = peer(TransportKind.nearby, 'ep1', prefix: 'bbbb0000');
    expect(r.update(p, t0), isTrue);
    expect(r.update(p, t0.add(const Duration(seconds: 3))), isFalse);
  });

  test('routes unseen for 15 s are dropped', () {
    r.update(peer(TransportKind.lan, 'a:1', prefix: 'aaaa0000'), t0);
    r.update(peer(TransportKind.ble, 'u', prefix: 'aaaa0000'),
        t0.add(const Duration(seconds: 10)));
    expect(r.sweep(t0.add(const Duration(seconds: 14))), isFalse);
    expect(r.sweep(t0.add(const Duration(seconds: 16))), isTrue);
    expect(r.peers.single.transports, {TransportKind.ble});
    expect(r.sweep(t0.add(const Duration(seconds: 26))), isTrue);
    expect(r.peers, isEmpty);
    expect(r.routesFor('aaaa0000'), isEmpty);
  });

  test('sharing peers sort first, then by name', () {
    r.update(peer(TransportKind.ble, '1', prefix: 'p1', name: 'Zed',
        tokens: {'tok-g1'}), t0);
    r.update(peer(TransportKind.ble, '2', prefix: 'p2', name: 'Amy'), t0);
    r.update(peer(TransportKind.ble, '3', prefix: 'p3', name: 'Bob'), t0);
    expect(r.peers.map((p) => p.name), ['Zed', 'Amy', 'Bob']);
  });

  test('a new token index re-evaluates shared groups', () {
    r.update(peer(TransportKind.ble, '1', prefix: 'p1', tokens: {'t-new'}), t0);
    expect(r.peers.single.sharesGroups, isFalse);
    r.tokenIndex = {'t-new': 'g9'};
    expect(r.peers.single.sharedGroupIds, ['g9']);
  });

  test('a new advert id on a known route keeps the row and its transports',
      () {
    r.update(peer(TransportKind.lan, '10.0.0.2:1', prefix: 'aaaa0000'), t0);
    r.update(peer(TransportKind.ble, 'u', prefix: 'aaaa0000'), t0);
    // The next token window: LAN shows the new id first, then BLE.
    final t1 = t0.add(const Duration(seconds: 1));
    r.update(peer(TransportKind.lan, '10.0.0.2:1', prefix: 'bbbb1111'), t1);
    r.update(peer(TransportKind.ble, 'u', prefix: 'bbbb1111'), t1);
    final p = r.peers.single;
    expect(p.key, 'aaaa0000');
    expect(p.advertId, 'bbbb1111');
    expect(p.transports, {TransportKind.lan, TransportKind.ble});
  });

  test('self advert ids can change; our own rows disappear', () {
    r.update(peer(TransportKind.lan, 'x', prefix: 'cccc2222'), t0);
    expect(r.peers, hasLength(1));
    r.selfAdvertIds = {'cccc2222'};
    expect(r.peers, isEmpty);
  });

  group('window tags', () {
    test('tokens match the window the advertiser names', () {
      r
        ..currentWindow = 5000
        ..setWindowIndex(5012, {'tok-later': 'g3'});
      r.update(
        const DiscoveredPeer(
          kind: TransportKind.nearby,
          address: 'ep',
          name: 'Priya',
          advertId: 'dddd3333',
          groupTokens: {'tok-later', 'tok-g1'},
          windowTag: 5012 % 4096,
        ),
        t0,
      );
      // Only the named window counts, not the scanner's own.
      expect(r.peers.single.sharedGroupIds, ['g3']);
      expect(r.windowsInUse, {5012});
    });

    test('a window more than two days away matches nothing', () {
      r.currentWindow = 5000;
      const far = DiscoveredPeer(
        kind: TransportKind.nearby,
        address: 'ep',
        name: 'Priya',
        groupTokens: {'tok-g1'},
        windowTag: (5000 + 400) % 4096,
      );
      expect(r.windowOf(far), isNull);
      r.update(far, t0);
      expect(r.peers.single.sharesGroups, isFalse);
    });

    test('adverts without a tag use the current-window index', () {
      r.currentWindow = 5000;
      r.update(peer(TransportKind.ble, 'u', tokens: {'tok-g1'}), t0);
      expect(r.peers.single.sharedGroupIds, ['g1']);
    });
  });

  test('advertised names are cleaned before they are listed', () {
    // SECURITY-R2-04.
    r.update(
      peer(TransportKind.lan, '10.0.0.2:1', name: 'Alex\u202E5000 diap'),
      t0,
    );
    expect(r.peers.single.name, 'Alex5000 diap');
  });

  test('a cut advert makes a phone worth trying; it sorts after sharers',
      () {
    // SYNC-R2-01.
    r.update(
      DiscoveredPeer(
        kind: TransportKind.nearby,
        address: 'E1',
        name: 'Busy phone',
        advertId: 'bbbb0000',
        moreGroups: true,
      ),
      t0,
    );
    r.update(peer(TransportKind.ble, 'u2', prefix: 'cccc0000', name: 'A'),
        t0);
    r.update(peer(TransportKind.lan, '10.0.0.3:1', prefix: 'dddd0000',
        name: 'Z', tokens: {'tok-g1'}), t0);
    expect(r.peers.map((p) => p.name), ['Z', 'Busy phone', 'A']);
    final busy = r.peers[1];
    expect(busy.sharesGroups, isFalse);
    expect(busy.moreGroups, isTrue);
    expect(busy.maySync, isTrue);
    expect(r.peers[2].maySync, isFalse);
  });

  // SECURITY-R15-01: a sighting rebuilds only the rows it touches. The
  // registry must still publish exactly what rebuilding every row did.
  test('seeded random operations publish what a full rebuild publishes',
      () {
    const kinds = TransportKind.values;
    const addresses = ['10.0.0.2:1', '10.0.0.3:1', 'uuid-1', 'E1', 'E2'];
    const ids = ['aaaa0001', 'aaaa0002', 'aaaa0003', 'mememe00', null];
    const names = ['Priya', 'Sam', '', 'Alex', 'priya'];
    const tokens = ['tok-g1', 'tok-g2', 'tok-w', 'nope'];
    const windows = [1000, 999, 1001, 3000];
    String sig(List<NearbyPeer> peers) => peers
        .map((p) => '${p.key}|${p.advertId}|${p.name}|${p.transports}|'
            '${p.sharedGroupIds}|${p.moreGroups}')
        .join('\n');
    for (var seed = 0; seed < 400; seed++) {
      final rng = Random(seed);
      T pick<T>(List<T> xs) => xs[rng.nextInt(xs.length)];
      final a = NearbyRegistry(ttl: const Duration(seconds: 5));
      final b = RebuildingRegistry(ttl: const Duration(seconds: 5));
      var now = t0;
      for (var i = 0, n = 1 + rng.nextInt(80); i < n; i++) {
        final op = rng.nextInt(20);
        final String what;
        if (op < 12) {
          final p = DiscoveredPeer(
            kind: pick(kinds),
            address: pick(addresses),
            name: pick(names),
            advertId: pick(ids),
            groupTokens: {
              for (var k = rng.nextInt(3); k > 0; k--) pick(tokens),
            },
            windowTag: rng.nextBool() ? null : pick(windows) % 4096,
            moreGroups: rng.nextInt(4) == 0,
          );
          what = 'update ${p.kind.name} ${p.address} ${p.advertId}';
          expect(a.update(p, now), b.update(p, now), reason: 'seed $seed $what');
        } else if (op < 15) {
          now = now.add(Duration(seconds: rng.nextInt(4)));
          what = 'sweep';
          expect(a.sweep(now), b.sweep(now), reason: 'seed $seed $what');
        } else if (op == 15) {
          what = 'tokenIndex';
          final index = {
            for (final t in tokens)
              if (rng.nextBool()) t: 'g${rng.nextInt(3)}',
          };
          a.tokenIndex = index;
          b.tokenIndex = index;
        } else if (op == 16) {
          what = 'currentWindow';
          final w = pick(windows);
          a.currentWindow = w;
          b.currentWindow = w;
        } else if (op == 17) {
          what = 'setWindowIndex';
          final w = pick(windows);
          final index = {pick(tokens): 'g${rng.nextInt(3)}'};
          expect(
            a.setWindowIndex(w, index),
            b.setWindowIndex(w, index),
            reason: 'seed $seed $what',
          );
        } else if (op == 18) {
          what = 'selfAdvertIds';
          final self = {pick(ids)}.whereType<String>().toSet();
          a.selfAdvertIds = self;
          b.selfAdvertIds = self;
        } else {
          what = rng.nextBool() ? 'clear' : 'clearWindowIndexes';
          if (what == 'clear') {
            a.clear();
            b.clear();
          } else {
            a.clearWindowIndexes();
            b.clearWindowIndexes();
          }
        }
        expect(sig(a.peers), sig(b.peers), reason: 'seed $seed after $what');
        expect(a.windowsInUse, b.windowsInUse, reason: 'seed $seed $what');
        for (final p in b.peers) {
          expect(
            a.routesFor(p.key).map((d) => '${d.kind}|${d.address}'),
            b.routesFor(p.key).map((d) => '${d.kind}|${d.address}'),
            reason: 'seed $seed $what ${p.key}',
          );
        }
      }
    }
  });

  group('SECURITY-R15-01: a stranger floods every transport', () {
    // Rebuilding every row per sighting took about 4 s for 1,200 forged
    // services and 8 s for each 5 s re-report of them.
    const n = 5000;
    const budget = Duration(seconds: 3);

    DiscoveredPeer forged(int i, {String? id}) => DiscoveredPeer(
          kind: TransportKind.lan,
          address: '10.0.0.66:${20000 + i}',
          name: 'Phone $i',
          advertId: id,
        );

    test('new services, their re-reports, and their expiry stay cheap', () {
      final r = NearbyRegistry();
      var sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        expect(r.update(forged(i), t0), isTrue);
      }
      expect(sw.elapsed, lessThan(budget), reason: 'new: ${sw.elapsed}');
      expect(r.peers, hasLength(n));
      sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        expect(r.update(forged(i), t0.add(const Duration(seconds: 5))),
            isFalse);
      }
      expect(sw.elapsed, lessThan(budget), reason: 're-report: ${sw.elapsed}');
      sw = Stopwatch()..start();
      expect(r.sweep(t0.add(const Duration(minutes: 1))), isTrue);
      expect(r.peers, isEmpty);
      expect(sw.elapsed, lessThan(budget), reason: 'expiry: ${sw.elapsed}');
    });

    test('a rotating advert id per service stays cheap', () {
      final r = NearbyRegistry();
      final sw = Stopwatch()..start();
      for (var i = 0; i < n; i++) {
        r.update(forged(i, id: 'id${i.toString().padLeft(6, '0')}'), t0);
      }
      for (var i = 0; i < n; i++) {
        // Same route, new id: an alias of the same row.
        r.update(forged(i, id: 'nx${i.toString().padLeft(6, '0')}'), t0);
      }
      expect(r.peers, hasLength(n));
      r.sweep(t0.add(const Duration(minutes: 1)));
      expect(r.peers, isEmpty);
      expect(sw.elapsed, lessThan(budget), reason: '${sw.elapsed}');
    });
  });
}
