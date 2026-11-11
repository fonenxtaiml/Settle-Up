// QA SECURITY round 15: full regression sweep.
//
// SECURITY-R15-01: since the SYNC-R8-01 fix, LAN (mDNS) and Nearby
// discovery keep every sighting not yet withdrawn in a SightingCache whose
// `visible` list is quadratic in the number of cached sightings, and every
// new sighting computes it twice. A stranger on the same Wi-Fi or hotspot
// who announces many `_settleup._tcp` services (one host, many ports or
// names, never sending a goodbye) makes each further sighting cost O(n^2)
// and the whole flood O(n^3) on the UI isolate while the Sync screen is
// open. Before the fix the cache was a plain map (O(1) per sighting).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/sighting_cache.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/lan/support.dart';

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

/// One forged service of the flood: one stranger host, a port per service.
(String, MdnsSighting?) _forged(int i) => (
  'Phone $i',
  MdnsSighting(
    name: 'Phone $i',
    addresses: const ['10.0.0.66'],
    port: 20000 + i,
    attributes: const {'v': '2', 't': ''},
  ),
);

const int _flood = 1200;

/// What processing the flood may take on a desktop test runner: a phone is
/// several times slower. A plain map handles 1,200 sightings in a few ms.
const Duration _budget = Duration(seconds: 2);

void main() {
  group('SECURITY-R15-01: a stranger floods discovery with mDNS services', () {
    test(
      'SightingCache takes $_flood sightings in linear time',
      () {
        final cache = SightingCache();
        final sw = Stopwatch()..start();
        for (var i = 0; i < _flood; i++) {
          cache.put(
            'svc$i',
            DiscoveredPeer(
              kind: TransportKind.lan,
              address: '10.0.0.66:${20000 + i}',
              name: 'Phone $i',
            ),
          );
        }
        sw.stop();
        expect(cache.visible, hasLength(_flood));
        expect(
          sw.elapsed,
          lessThan(_budget),
          reason: '$_flood sightings took ${sw.elapsedMilliseconds} ms',
        );
      },
      skip:
          'QA SECURITY-R15-01: a stranger flooding mDNS adverts makes '
          'discovery cubic and freezes the Sync screen',
    );

    test(
      'LanTransport.discover takes $_flood forged services in linear time',
      () async {
        final mdns = _ScriptedMdns();
        final t = LanTransport(
          port: 0,
          mdns: mdns,
          network: FakeLanNetwork(),
          rediscoverInterval: const Duration(hours: 1),
          probeInterval: const Duration(hours: 1),
        );
        addTearDown(t.dispose);
        final seen = <String>{};
        final sub = t.discover().listen((p) => seen.add(p.address));
        addTearDown(sub.cancel);
        await Future<void>.delayed(Duration.zero);
        final sw = Stopwatch()..start();
        for (var i = 0; i < _flood; i++) {
          mdns.deliver(_forged(i));
        }
        while (seen.length < _flood &&
            sw.elapsed < const Duration(minutes: 2)) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        sw.stop();
        expect(seen, hasLength(_flood));
        expect(
          sw.elapsed,
          lessThan(_budget),
          reason: '$_flood sightings took ${sw.elapsedMilliseconds} ms',
        );
      },
      skip:
          'QA SECURITY-R15-01: a stranger flooding mDNS adverts makes '
          'discovery cubic and freezes the Sync screen',
    );

    test('a single service re-announced many times stays cheap', () {
      // Control: one key overwritten is the common, legitimate case.
      final cache = SightingCache();
      final sw = Stopwatch()..start();
      for (var i = 0; i < _flood; i++) {
        cache.put(
          'svc',
          const DiscoveredPeer(
            kind: TransportKind.lan,
            address: '10.0.0.2:52741',
            name: 'Asha',
          ),
        );
      }
      expect(cache.visible, hasLength(1));
      expect(sw.elapsed, lessThan(_budget));
    });
  });
}
