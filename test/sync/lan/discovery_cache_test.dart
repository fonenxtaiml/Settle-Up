// LanTransport.discover() keeps one cached service per advertiser
// (SYNC-R6-01): mDNS caches services by name, so after a rename whose
// goodbye is missed the old name must not be re-emitted next to the new
// one. Driven by a scripted mDNS backend that delivers exactly the events
// a test gives it (resolves, late resolves, late or missing goodbyes).
import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'support.dart';

const Duration _round = Duration(milliseconds: 15);

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

  bool get browsing => _browses.isNotEmpty;

  void deliver((String, MdnsSighting?) event) {
    for (final b in _browses) {
      b.add(event);
    }
  }
}

/// A resolved service [name] at [host]:[port] with advert id [id].
(String, MdnsSighting?) resolved(
  String name, {
  String host = '10.0.0.2',
  int port = 52741,
  String? id = 'abcd1234',
}) => (
  name,
  MdnsSighting(
    name: name,
    addresses: [host],
    port: port,
    attributes: {'v': '2', 'd': ?id, 't': ''},
  ),
);

(String, MdnsSighting?) goodbye(String name) => (name, null);

void main() {
  late _ScriptedMdns mdns;
  late LanTransport t;

  setUp(() {
    mdns = _ScriptedMdns();
    t = LanTransport(
      port: 0,
      mdns: mdns,
      network: FakeLanNetwork(),
      rediscoverInterval: _round,
      probeInterval: const Duration(hours: 1),
    );
  });

  tearDown(() => t.dispose());

  /// Delivers [events], then returns what the next few re-discovery rounds
  /// emit, as 'address/name/advertId'.
  Future<Set<String>> shownAfter(List<(String, MdnsSighting?)> events) async {
    final seen = <DiscoveredPeer>[];
    final sub = t.discover().listen(seen.add);
    await Future<void>.delayed(Duration.zero);
    expect(mdns.browsing, isTrue);
    for (final e in events) {
      mdns.deliver(e);
      await Future<void>.delayed(Duration.zero);
    }
    await Future<void>.delayed(_round ~/ 2);
    seen.clear();
    await Future<void>.delayed(_round * 4);
    await sub.cancel();
    return {for (final p in seen) '${p.address}/${p.name}/${p.advertId}'};
  }

  group('SYNC-R6-01: one cached service per advertiser', () {
    test('a rename whose goodbye is missed shows only the new name', () async {
      expect(
        await shownAfter([resolved('Pixel 8'), resolved("Alex's phone")]),
        {"10.0.0.2:52741/Alex's phone/abcd1234"},
      );
    });

    test('the same address with a new advert id (rename across a window '
        'change) replaces the old service', () async {
      expect(
        await shownAfter([
          resolved('Pixel 8', id: 'abcd1234'),
          resolved("Alex's phone", id: 'ffff0000'),
        ]),
        {"10.0.0.2:52741/Alex's phone/ffff0000"},
      );
    });

    test('the same advert id at a new address (the phone moved) replaces '
        'the old service', () async {
      expect(
        await shownAfter([
          resolved('Pixel 8', host: '10.0.0.2'),
          resolved("Alex's phone", host: '10.0.0.9'),
        ]),
        {"10.0.0.9:52741/Alex's phone/abcd1234"},
      );
    });

    test('a late goodbye of the old name keeps the new one', () async {
      expect(
        await shownAfter([
          resolved('Pixel 8'),
          resolved("Alex's phone"),
          goodbye('Pixel 8'),
        ]),
        {"10.0.0.2:52741/Alex's phone/abcd1234"},
      );
    });

    test('a goodbye of the new name does not bring the old one back', () async {
      expect(
        await shownAfter([
          resolved('Pixel 8'),
          resolved("Alex's phone"),
          goodbye("Alex's phone"),
        ]),
        isEmpty,
      );
    });

    test('renaming back shows the first name again', () async {
      expect(
        await shownAfter([
          resolved('Pixel 8'),
          resolved("Alex's phone"),
          resolved('Pixel 8'),
        ]),
        {'10.0.0.2:52741/Pixel 8/abcd1234'},
      );
    });

    test('two phones with the same name stay two', () async {
      expect(
        await shownAfter([
          resolved('Pixel 8', host: '10.0.0.2', id: 'aaaa0001'),
          resolved('Pixel 8 (2)', host: '10.0.0.3', id: 'aaaa0002'),
        ]),
        {
          '10.0.0.2:52741/Pixel 8/aaaa0001',
          '10.0.0.3:52741/Pixel 8 (2)/aaaa0002',
        },
      );
    });

    test('phones on one host but different ports stay two', () async {
      expect(
        await shownAfter([
          resolved('A', port: 52741, id: null),
          resolved('B', port: 52742, id: null),
        ]),
        {'10.0.0.2:52741/A/null', '10.0.0.2:52742/B/null'},
      );
    });

    test('services without an advert id merge only by address', () async {
      expect(
        await shownAfter([
          resolved('A', host: '10.0.0.2', id: null),
          resolved('B', host: '10.0.0.3', id: null),
          resolved('C', host: '10.0.0.2', id: null),
        ]),
        {'10.0.0.3:52741/B/null', '10.0.0.2:52741/C/null'},
      );
    });

    test('seeded random event sequences: never two rows for one advertiser, '
        'and each row is that advertiser\'s newest sighting', () async {
      const names = ['Pixel 8', "Alex's phone", 'Priya', 'Sam', 'Pixel 8 2'];
      const hosts = ['10.0.0.2', '10.0.0.3', '10.0.0.4'];
      const ids = ['aaaa0001', 'aaaa0002', 'aaaa0003', null];
      for (var seed = 0; seed < 40; seed++) {
        final rng = Random(seed);
        final events = <(String, MdnsSighting?)>[];
        // Reference model: newest sighting per advertiser, applied in order.
        final live = <String, DiscoveredPeer>{};
        for (var i = 0, n = 1 + rng.nextInt(12); i < n; i++) {
          final name = names[rng.nextInt(names.length)];
          if (rng.nextInt(4) == 0) {
            events.add(goodbye(name));
            live.remove(name);
            continue;
          }
          final e = resolved(
            name,
            host: hosts[rng.nextInt(hosts.length)],
            port: 52741 + rng.nextInt(2),
            id: ids[rng.nextInt(ids.length)],
          );
          events.add(e);
          final peer = e.$2!.toPeer()!;
          live.removeWhere((k, p) => k == name || peer.sameAdvertiserAs(p));
          live[name] = peer;
        }

        await t.dispose();
        mdns = _ScriptedMdns();
        t = LanTransport(
          port: 0,
          mdns: mdns,
          network: FakeLanNetwork(),
          rediscoverInterval: _round,
          probeInterval: const Duration(hours: 1),
        );
        final shown = await shownAfter(events);
        expect(shown, {
          for (final p in live.values) '${p.address}/${p.name}/${p.advertId}',
        }, reason: 'seed $seed: $events');
        // Independent of the model: no two rows share an address or id.
        final rows = shown.map((s) => s.split('/')).toList();
        for (var i = 0; i < rows.length; i++) {
          for (var j = i + 1; j < rows.length; j++) {
            expect(rows[i][0], isNot(rows[j][0]), reason: 'seed $seed');
            if (rows[i][2] != 'null') {
              expect(rows[i][2], isNot(rows[j][2]), reason: 'seed $seed');
            }
          }
        }
      }
    });
  });

  test('sameAdvertiserAs: same kind and same address or advert id', () {
    const a = DiscoveredPeer(
      kind: TransportKind.lan,
      address: '10.0.0.2:1',
      name: 'A',
      advertId: 'abcd1234',
    );
    DiscoveredPeer p({
      TransportKind kind = TransportKind.lan,
      String address = '10.0.0.9:1',
      String? id,
    }) => DiscoveredPeer(kind: kind, address: address, name: 'B', advertId: id);
    expect(a.sameAdvertiserAs(p(address: '10.0.0.2:1')), isTrue);
    expect(a.sameAdvertiserAs(p(id: 'abcd1234')), isTrue);
    expect(a.sameAdvertiserAs(p()), isFalse);
    expect(a.sameAdvertiserAs(p(id: 'abcd0000')), isFalse);
    expect(
      a.sameAdvertiserAs(p(kind: TransportKind.nearby, id: 'abcd1234')),
      isFalse,
    );
    const noId = DiscoveredPeer(
      kind: TransportKind.lan,
      address: '10.0.0.3:1',
      name: 'C',
    );
    expect(noId.sameAdvertiserAs(p()), isFalse);
  });
}
