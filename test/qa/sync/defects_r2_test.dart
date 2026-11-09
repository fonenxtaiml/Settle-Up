// QA SYNC-R2: repro tests for defects found in round 2. Each one FAILS on
// the code under test and is skipped with its finding id so the suite
// stays green. Remove the skip once the fix lands.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/sync/crypto/tokens.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/ble/ble_info.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/support/phone.dart' show groupIdOf, groupKeyOf;
import 'qa_phone.dart';

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

  group('SYNC-R2-01: a phone in more groups than the advert holds', () {
    // 3 trips + 1:1 friend groups (directGroupWith makes one per friend).
    // The scanner shares exactly one of them. Over 24 token windows (4 h),
    // count the windows in which the shared group's token is not in the
    // advert as decoded by the real encoders.
    Future<int> missed(
      int groups,
      Set<String> Function(AdvertiseInfo) decode,
    ) async {
      final keys = {
        for (var i = 0; i < groups; i++) groupIdOf(i + 1): groupKeyOf(i),
      };
      final shared = groupIdOf(7);
      final scannerKeys = {shared: keys[shared]!};
      final start = DateTime.utc(2026, 11, 9, 12);
      var out = 0;
      for (var w = 0; w < 24; w++) {
        final t = start.add(Duration(minutes: 10 * w));
        final win = DiscoveryTokens.windowAt(t);
        final advert = AdvertiseInfo(
          deviceId: 'aaaaaaaa-0000-7000-8000-000000000001',
          deviceName: 'Alex',
          groupTokens: await DiscoveryTokens.advertised(keys, t),
          advertId: 'abcdef01',
          tokenWindow: win,
        );
        final index = await DiscoveryTokens.indexForWindow(scannerKeys, win);
        if (!decode(advert).any(index.containsKey)) out++;
      }
      return out;
    }

    final decoders = <String, Set<String> Function(AdvertiseInfo)>{
      'nearby': (a) =>
          NearbyEndpointName.tryParse(NearbyEndpointName.of(a).encode())!
              .groupTokens
              .toSet(),
      'ble': (a) =>
          BleInfo.tryParse(BleInfo.of(a).encode())!.groupTokens.toSet(),
      'lan': (a) => MdnsSighting(
            name: 'Alex',
            addresses: const ['192.168.1.20'],
            port: 47321,
            attributes: MdnsAdvert.of(a, 47321).attributes,
          ).toPeer()!.groupTokens,
    };

    for (final (name, groups) in const [
      ('nearby', 30),
      ('ble', 60),
      ('lan', 60),
    ]) {
      test(
        'over $name with $groups groups, the shared group is recognised in '
        'every token window',
        () async {
          final n = await missed(groups, decoders[name]!);
          expect(
            n,
            0,
            reason: 'shared group hidden in $n of 24 windows over $name: '
                'the Sync screen shows "Pair" and refuses tap-to-sync',
          );
        },
        skip: 'SYNC-R2-01',
      );
    }
  });

  test(
    'SYNC-R2-02: both phones tap Sync while one dial is slower than the '
    'handshake timeout; nobody is told another phone is syncing',
    () async {
      // fastTimings: handshakeTimeout 2 s. Priya's dial takes 3 s (in
      // production: a LAN route that hangs for its 10 s connect timeout
      // before Nearby is tried, against a 10 s handshake timeout).
      final alex = await QaPhone.create(hub, 'a', "Alex's Pixel");
      final priya = await QaPhone.create(
        hub,
        'b',
        "Priya's Pixel",
        wrap: (t) => SlowConnectTransport(t, const Duration(seconds: 3)),
      );
      phones.addAll([alex, priya]);
      final seed = await alex.seedGroup(expenses: 3);
      await priya.join(alex, seed.g);
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      final toAlex = await priya.find(alex);
      Future<Object> tap(QaPhone p, NearbyPeer to) => p.engine
          .syncWith(to)
          .then<Object>((s) => s, onError: (Object e) => e);
      final fp = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final fa = tap(alex, toPriya);
      final results =
          await Future.wait([fa, fp]).timeout(const Duration(seconds: 15));
      expect(results.whereType<SyncSummary>(), isNotEmpty);
      for (final r in results.whereType<SyncException>()) {
        expect(
          r.message,
          isNot(contains('another phone')),
          reason: 'Alex and Priya only ever tried each other: $results',
        );
      }
    },
    skip: 'SYNC-R2-02',
  );
}
