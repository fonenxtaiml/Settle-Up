// SightingCache (SYNC-R6-01, SYNC-R8-01): every sighting stays cached
// until its own withdrawal, and only the newest one per advertiser is
// visible. Seeded random sequences check the invariants directly.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/lan/sighting_cache.dart';
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
}
