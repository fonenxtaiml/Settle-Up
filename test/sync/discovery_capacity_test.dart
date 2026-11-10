// SYNC-R2-01: a phone in more groups than an advert holds (every 1:1
// friend is a group). Adverts keep the same groups in every window
// (recently synced first, then the newest), sort what they keep, and say
// when they cut the list, so a scanner can still offer Sync.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/sync/crypto/tokens.dart';
import 'package:settle_up/sync/nearby_registry.dart';
import 'package:settle_up/sync/transport/ble/ble_info.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'support/phone.dart' show groupIdOf, groupKeyOf;

void main() {
  final start = DateTime.utc(2026, 11, 9, 12);
  Map<GroupId, Uint8List> keysFor(int n) => {
        for (var i = 0; i < n; i++) groupIdOf(i + 1): groupKeyOf(i),
      };

  group('DiscoveryTokens.advertised', () {
    test('lists priority groups first, then the newest, stably', () async {
      final keys = keysFor(5);
      final w = DiscoveryTokens.windowAt(start);
      Future<String> t(int n) => DiscoveryTokens.token(keys[groupIdOf(n)]!, w);
      expect(
        await DiscoveryTokens.advertised(
          keys,
          start,
          priority: [groupIdOf(2), 'not-mine', groupIdOf(2)],
        ),
        [await t(2), await t(5), await t(4), await t(3), await t(1)],
      );
    });

    test('forAdvert keeps a sorted prefix and reports the cut', () {
      final kept = DiscoveryTokens.forAdvert(['zzzz', 'bad', 'aaaa', 'mmmm'], 2);
      expect(kept.tokens, ['aaaa', 'zzzz']);
      expect(kept.cut, isTrue);
      final all = DiscoveryTokens.forAdvert(['zzzz', 'aaaa'], 2);
      expect(all.tokens, ['aaaa', 'zzzz']);
      expect(all.cut, isFalse);
    });
  });

  /// Decoders as the real transports run them.
  final decoders = <String, DiscoveredPeer Function(AdvertiseInfo)>{
    'nearby': (a) => NearbyEndpointName.tryParse(
          NearbyEndpointName.of(a).encode(),
        )!.toPeer('E1'),
    'ble': (a) => BleInfo.tryParse(BleInfo.of(a).encode())!.toPeer('uuid-1'),
    'lan': (a) => MdnsSighting(
          name: a.deviceName,
          addresses: const ['192.168.1.20'],
          port: 47321,
          attributes: MdnsAdvert.of(a, 47321).attributes,
        ).toPeer()!,
  };

  for (final (name, groups) in const [
    ('nearby', 40),
    ('ble', 120),
    ('lan', 300),
  ]) {
    test(
        'over $name with $groups groups, a phone sharing the oldest group '
        'can be synced with in every window', () async {
      final keys = keysFor(groups);
      // The oldest group: last in priority, so cut from the advert.
      final shared = groupIdOf(1);
      for (var w = 0; w < 24; w++) {
        final t = start.add(Duration(minutes: 10 * w));
        final window = DiscoveryTokens.windowAt(t);
        final advert = AdvertiseInfo(
          deviceId: 'aaaaaaaa-0000-7000-8000-000000000001',
          deviceName: 'Alex',
          groupTokens: await DiscoveryTokens.advertised(keys, t),
          advertId: 'abcdef01',
          tokenWindow: window,
        );
        final peer = decoders[name]!(advert);
        expect(peer.moreGroups, isTrue);
        final tokens = peer.groupTokens.toList();
        expect([...tokens]..sort(), tokens, reason: 'adverts are sorted');
        final registry = NearbyRegistry()..currentWindow = window;
        registry.setWindowIndex(
          window,
          await DiscoveryTokens.indexForWindow(
            {shared: keys[shared]!},
            window,
          ),
        );
        registry.update(peer, t);
        final listed = registry.peers.single;
        expect(listed.sharesGroups, isFalse);
        expect(listed.maySync, isTrue, reason: 'window $w');
      }
    });

    test('over $name, a recently synced group is in every window', () async {
      final keys = keysFor(groups);
      final shared = groupIdOf(1);
      for (var w = 0; w < 24; w++) {
        final t = start.add(Duration(minutes: 10 * w));
        final window = DiscoveryTokens.windowAt(t);
        final peer = decoders[name]!(AdvertiseInfo(
          deviceId: 'aaaaaaaa-0000-7000-8000-000000000001',
          deviceName: 'Alex',
          groupTokens: await DiscoveryTokens.advertised(
            keys,
            t,
            priority: [shared],
          ),
          advertId: 'abcdef01',
          tokenWindow: window,
        ));
        final index = await DiscoveryTokens.indexForWindow(
          {shared: keys[shared]!},
          window,
        );
        expect(peer.groupTokens.any(index.containsKey), isTrue,
            reason: 'window $w');
      }
    });
  }

  test('a phone whose advert holds every token is not flagged', () async {
    final keys = keysFor(NearbyEndpointName.maxTokens);
    final peer = decoders['nearby']!(AdvertiseInfo(
      deviceId: 'aaaaaaaa-0000-7000-8000-000000000001',
      deviceName: 'Alex',
      groupTokens: await DiscoveryTokens.advertised(keys, start),
    ));
    expect(peer.moreGroups, isFalse);
    expect(peer.groupTokens, hasLength(NearbyEndpointName.maxTokens));
  });
}
