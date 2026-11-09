import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/nearby_registry.dart';
import 'package:settle_up/sync/transport/transport.dart';

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
}
