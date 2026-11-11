// SightingCache (SYNC-R6-01, SYNC-R8-01): every sighting stays cached
// until its own withdrawal, and only the newest one per advertiser is
// visible. Seeded random sequences check the invariants directly.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/sighting_cache.dart';
import 'package:settle_up/sync/transport/transport.dart';

DiscoveredPeer _peer(String name, String address, String? id) => DiscoveredPeer(
  kind: TransportKind.lan,
  address: address,
  name: name,
  advertId: id,
);

Set<String> _names(Iterable<DiscoveredPeer> peers) => {
  for (final p in peers) p.name,
};

void main() {
  test('a stale old name resolved after the new one is shown, and its '
      'withdrawal shows the new one again (SYNC-R8-01)', () {
    final c = SightingCache();
    final live = _peer("Alex's phone", '10.0.0.2:52741', 'abcd1234');
    final stale = _peer('Pixel 8', '10.0.0.2:52741', 'abcd1234');
    expect(c.put("Alex's phone", live), isEmpty);
    expect(c.put('Pixel 8', stale), [live]);
    expect(c.visible, [stale]);
    final r = c.remove('Pixel 8');
    expect(r.removed, stale);
    expect(r.shown, [live]);
    expect(c.visible, [live]);
    expect(c.isVisible("Alex's phone"), isTrue);
  });

  test('a withdrawal of a hidden sighting changes nothing visible', () {
    final c = SightingCache();
    final old = _peer('Pixel 8', '10.0.0.2:52741', 'abcd1234');
    final now = _peer("Alex's phone", '10.0.0.2:52741', 'abcd1234');
    c.put('Pixel 8', old);
    c.put("Alex's phone", now);
    final r = c.remove('Pixel 8');
    expect(r.removed, old);
    expect(r.shown, isEmpty);
    expect(c.visible, [now]);
  });

  test('withdrawing an unknown key is a no-op', () {
    final c = SightingCache();
    final r = c.remove('nobody');
    expect(r.removed, isNull);
    expect(r.shown, isEmpty);
    expect(c.isEmpty, isTrue);
  });

  test('a chain of re-adverts (new address, then new advert id) is one '
      'phone', () {
    final c = SightingCache();
    c.put('A', _peer('A', '10.0.0.2:1', 'id000001'));
    c.put('B', _peer('B', '10.0.0.2:1', 'id000002'));
    c.put('C', _peer('C', '10.0.0.9:1', 'id000002'));
    expect(_names(c.visible), {'C'});
    c.remove('C');
    expect(_names(c.visible), {'B'});
    c.remove('B');
    expect(_names(c.visible), {'A'});
  });

  test('seeded random puts and withdrawals: one row per phone, the newest '
      'without a withdrawal, and no phone with a cached sighting is ever '
      'hidden', () {
    const keys = ['Pixel 8', "Alex's phone", 'Priya', 'Sam', 'Pixel 8 2', 'X'];
    const hosts = ['10.0.0.2:52741', '10.0.0.3:52741', '10.0.0.2:52742'];
    const ids = ['aaaa0001', 'aaaa0002', 'aaaa0003', null];
    for (var seed = 0; seed < 500; seed++) {
      final rng = Random(seed);
      final c = SightingCache();
      // Reference: key -> peer in order of the latest put.
      final model = <String, DiscoveredPeer>{};
      for (var i = 0, n = 1 + rng.nextInt(30); i < n; i++) {
        final key = keys[rng.nextInt(keys.length)];
        final before = c.visible;
        if (rng.nextInt(3) == 0) {
          final r = c.remove(key);
          expect(
            identical(r.removed, model.remove(key)),
            isTrue,
            reason: 'seed $seed',
          );
          for (final p in r.shown) {
            expect(
              before.any((q) => identical(p, q)),
              isFalse,
              reason: 'seed $seed: shown only when newly visible',
            );
          }
        } else {
          final p = _peer(
            '$key#$i',
            hosts[rng.nextInt(hosts.length)],
            ids[rng.nextInt(ids.length)],
          );
          final hidden = c.put(key, p);
          model.remove(key);
          model[key] = p;
          for (final h in hidden) {
            expect(
              before.any((q) => identical(h, q)),
              isTrue,
              reason: 'seed $seed',
            );
            expect(
              c.visible.any((q) => identical(h, q)),
              isFalse,
              reason: 'seed $seed',
            );
          }
        }
        final order = model.values.toList();
        final expected = [
          for (var j = 0; j < order.length; j++)
            if (!order.skip(j + 1).any((o) => o.sameAdvertiserAs(order[j])))
              order[j],
        ];
        final visible = c.visible;
        expect(_names(visible), _names(expected), reason: 'seed $seed');
        expect(_names(c.all), _names(model.values), reason: 'seed $seed');
        // No two visible rows are the same phone.
        for (var a = 0; a < visible.length; a++) {
          for (var b = a + 1; b < visible.length; b++) {
            expect(
              visible[a].sameAdvertiserAs(visible[b]),
              isFalse,
              reason: 'seed $seed',
            );
          }
        }
        // Every cached sighting is visible or has a visible sighting of
        // the same phone (directly or through a chain of re-adverts), so a
        // withdrawal never hides a phone that still has a cached service.
        for (final p in model.values) {
          final phone = Set<DiscoveredPeer>.identity()..add(p);
          var grew = true;
          while (grew) {
            grew = false;
            for (final o in model.values) {
              if (!phone.contains(o) && phone.any(o.sameAdvertiserAs)) {
                phone.add(o);
                grew = true;
              }
            }
          }
          expect(
            phone.any((q) => visible.any((v) => identical(v, q))),
            isTrue,
            reason: 'seed $seed: ${p.name} has no visible row',
          );
        }
      }
    }
  });

  // SECURITY-R15-01: the cache is indexed instead of scanned. It must
  // still answer exactly what the scanning definition answers, including
  // the order of what put() hides and remove() shows.
  test('seeded random operations: put, remove, visible, isVisible and '
      'showsAddress match the scanning reference exactly', () {
    const keys = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
    const hosts = ['10.0.0.2:1', '10.0.0.3:1', '10.0.0.2:2', '10.0.0.4:1'];
    const ids = ['id000001', 'id000002', 'id000003', null, null];
    const kinds = [TransportKind.lan, TransportKind.lan, TransportKind.nearby];
    for (var seed = 0; seed < 1000; seed++) {
      final rng = Random(seed);
      final c = SightingCache();
      final ref = _ScanningCache();
      final pool = <String, DiscoveredPeer>{};
      for (var i = 0, n = 1 + rng.nextInt(60); i < n; i++) {
        final key = keys[rng.nextInt(keys.length)];
        final op = rng.nextInt(10);
        if (op < 3) {
          final r = c.remove(key);
          final e = ref.remove(key);
          expect(identical(r.removed, e.removed), isTrue, reason: 'seed $seed');
          _expectSame(r.shown, e.shown, 'seed $seed shown');
        } else if (op == 3) {
          c.clear();
          ref.clear();
        } else {
          // A transport builds a new peer per event, but re-putting the
          // very object last put under this key (a replayed event) must
          // match too.
          final last = pool[key];
          final p = last != null && rng.nextInt(4) == 0
              ? last
              : DiscoveredPeer(
                  kind: kinds[rng.nextInt(kinds.length)],
                  address: hosts[rng.nextInt(hosts.length)],
                  name: '$key#$i',
                  advertId: ids[rng.nextInt(ids.length)],
                );
          pool[key] = p;
          _expectSame(c.put(key, p), ref.put(key, p), 'seed $seed hidden');
        }
        _expectSame(c.visible, ref.visible, 'seed $seed visible');
        _expectSame(c.all, ref.all, 'seed $seed all');
        expect(c.isEmpty, ref.isEmpty, reason: 'seed $seed');
        for (final k in keys) {
          expect(c.isVisible(k), ref.isVisible(k), reason: 'seed $seed $k');
        }
        for (final h in [...hosts, '10.0.0.9:1']) {
          expect(
            c.showsAddress(h),
            ref.visible.any((p) => p.address == h),
            reason: 'seed $seed $h',
          );
        }
      }
    }
  });

  group('SECURITY-R15-01: forged floods stay cheap', () {
    // A plain scan of 20,000 sightings per operation would take minutes.
    const n = 20000;
    const budget = Duration(seconds: 3);

    DiscoveredPeer forged(int i, {String? address, String? id}) =>
        DiscoveredPeer(
          kind: TransportKind.lan,
          address: address ?? '10.0.0.66:${20000 + i}',
          name: 'Phone $i',
          advertId: id,
        );

    void timed(String what, void Function() body) {
      final sw = Stopwatch()..start();
      body();
      expect(sw.elapsed, lessThan(budget), reason: '$what: ${sw.elapsed}');
    }

    test('many services, each its own address, then all their goodbyes', () {
      final c = SightingCache();
      timed('puts', () {
        for (var i = 0; i < n; i++) {
          expect(c.put('svc$i', forged(i)), isEmpty);
          expect(c.showsAddress('10.0.0.66:${20000 + i}'), isTrue);
        }
      });
      expect(c.visible, hasLength(n));
      timed('goodbyes', () {
        for (var i = 0; i < n; i++) {
          expect(c.remove('svc$i').shown, isEmpty);
        }
      });
      expect(c.isEmpty, isTrue);
    });

    test('many names for one address: each hides the last, and goodbyes '
        'newest first show each older one again', () {
      final c = SightingCache();
      timed('puts', () {
        for (var i = 0; i < n; i++) {
          final hidden = c.put('svc$i', forged(i, address: '10.0.0.66:1'));
          expect(hidden, hasLength(i == 0 ? 0 : 1));
        }
      });
      expect(c.visible.single.name, 'Phone ${n - 1}');
      timed('goodbyes', () {
        for (var i = n - 1; i > 0; i--) {
          expect(c.remove('svc$i').shown.single.name, 'Phone ${i - 1}');
        }
      });
    });

    test('many addresses for one advert id, goodbyes oldest first', () {
      final c = SightingCache();
      timed('puts', () {
        for (var i = 0; i < n; i++) {
          c.put('svc$i', forged(i, id: 'abcd1234'));
        }
      });
      expect(c.visible.single.name, 'Phone ${n - 1}');
      timed('goodbyes', () {
        for (var i = 0; i < n - 1; i++) {
          expect(c.remove('svc$i').shown, isEmpty);
          expect(c.isVisible('svc${n - 1}'), isTrue);
        }
      });
    });

    test('one service re-announced at ever new addresses', () {
      final c = SightingCache();
      timed('puts', () {
        for (var i = 0; i < n; i++) {
          c.put('svc', forged(i));
        }
      });
      expect(c.all, hasLength(1));
      expect(c.showsAddress('10.0.0.66:20000'), isFalse);
    });
  });
}

void _expectSame(
  Iterable<DiscoveredPeer> actual,
  Iterable<DiscoveredPeer> expected,
  String reason,
) {
  final a = actual.toList();
  final e = expected.toList();
  expect(a.length, e.length, reason: '$reason: $a vs $e');
  for (var i = 0; i < a.length; i++) {
    expect(identical(a[i], e[i]), isTrue, reason: '$reason [$i]: $a vs $e');
  }
}

/// The definition of [SightingCache] as a scan of every sighting (the
/// implementation before SECURITY-R15-01, quadratic per operation).
final class _ScanningCache {
  final Map<String, ({DiscoveredPeer peer, int seq})> _all = {};
  int _seq = 0;

  bool get isEmpty => _all.isEmpty;
  Iterable<DiscoveredPeer> get all => _all.values.map((e) => e.peer);
  List<DiscoveredPeer> get visible => [
    for (final e in _all.values)
      if (!_hidden(e)) e.peer,
  ];
  bool isVisible(String key) {
    final e = _all[key];
    return e != null && !_hidden(e);
  }

  bool _hidden(({DiscoveredPeer peer, int seq}) e) =>
      _all.values.any((o) => o.seq > e.seq && o.peer.sameAdvertiserAs(e.peer));

  List<DiscoveredPeer> put(String key, DiscoveredPeer peer) {
    final before = visible;
    _all[key] = (peer: peer, seq: ++_seq);
    final now = visible;
    return [
      for (final p in before)
        if (!now.any((q) => identical(q, p))) p,
    ];
  }

  ({DiscoveredPeer? removed, List<DiscoveredPeer> shown}) remove(String key) {
    final before = visible;
    final gone = _all.remove(key);
    if (gone == null) return (removed: null, shown: const []);
    return (
      removed: gone.peer,
      shown: [
        for (final p in visible)
          if (!before.any((q) => identical(q, p))) p,
      ],
    );
  }

  void clear() => _all.clear();
}
