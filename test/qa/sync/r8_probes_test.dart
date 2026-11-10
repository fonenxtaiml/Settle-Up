// QA SYNC round 8: probes around the SYNC-R6-01 fix (LanTransport keeps one
// cached mDNS service per advertiser, so a rename whose goodbye is missed
// no longer leaves the old name listed next to the new one), through the
// real DefaultSyncEngine and Ledger over the real LanTransport on
// 127.0.0.1 (mDNS faked), plus scripted-mDNS checks of the cache itself.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/lan/support.dart';
import 'qa_phone.dart';

/// A browser that behaves like Android's mDNS cache on a lossy hotspot:
/// goodbyes never arrive, every service it has resolved stays in its cache
/// (across browse restarts) until [expire] drops it, and a new browse also
/// answers stale cached services from that cache, after the live ones (the
/// resolve order of a fresh browse is not defined).
final class _OsCacheMdns implements MdnsBackend {
  _OsCacheMdns(this.inner);
  final FakeMdns inner;
  final Map<String, MdnsSighting> _cache = {};
  final List<StreamController<(String, MdnsSighting?)>> _browses = [];

  @override
  Future<void> advertise(MdnsAdvert advert) => inner.advertise(advert);
  @override
  Future<void> stopAdvertising() => inner.stopAdvertising();

  /// The record TTL of [name] ran out: the OS reports it lost.
  void expire(String name) {
    if (_cache.remove(name) == null) return;
    for (final b in _browses) {
      b.add((name, null));
    }
  }

  @override
  Stream<(String, MdnsSighting?)> browse() {
    late StreamController<(String, MdnsSighting?)> ctl;
    StreamSubscription<(String, MdnsSighting?)>? sub;
    final live = <String>{};
    ctl = StreamController(
      onListen: () {
        _browses.add(ctl);
        sub = inner.browse().listen((e) {
          final (name, s) = e;
          if (s == null) return; // The goodbye is missed.
          live.add(name);
          _cache[name] = s;
          ctl.add(e);
        });
        // Stale entries from the OS cache resolve after the live ones.
        Timer(const Duration(milliseconds: 30), () {
          if (ctl.isClosed) return;
          for (final MapEntry(:key, :value) in _cache.entries.toList()) {
            if (!live.contains(key)) ctl.add((key, value));
          }
        });
      },
      onCancel: () async {
        _browses.remove(ctl);
        await sub?.cancel();
      },
    );
    return ctl.stream;
  }
}

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

(String, MdnsSighting?) _resolved(String name, {String id = 'abcd1234'}) => (
  name,
  MdnsSighting(
    name: name,
    addresses: const ['10.0.0.2'],
    port: 52741,
    attributes: {'v': '2', 'd': id, 't': ''},
  ),
);

final class _LanPhone {
  _LanPhone(this.settings, this.ledger, this.engine);
  final KvSettingsRepository settings;
  final Ledger ledger;
  final DefaultSyncEngine engine;

  static Future<_LanPhone> create(
    String letter,
    String name,
    MdnsBackend mdns, {
    String displayName = 'Alex',
    Duration nearbyTtl = const Duration(milliseconds: 600),
  }) async {
    final store = MemoryOpStore();
    await store.open();
    final ids = PhoneIds(letter);
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: name,
      ids: ids,
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(
      displayName: displayName,
      homeCurrency: 'INR',
    );
    final ledger = await Ledger.open(
      store: store,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
    );
    final lan = LanTransport(
      port: 0,
      mdns: mdns,
      network: FakeLanNetwork(),
      bindAddress: InternetAddress.loopbackIPv4,
      rediscoverInterval: const Duration(milliseconds: 100),
      probeInterval: const Duration(seconds: 30),
      firstFrameTimeout: const Duration(seconds: 2),
    );
    final engine = DefaultSyncEngine(
      store: ledger,
      transports: [lan],
      timings: fastTimings,
      linkConnectTimeout: const Duration(seconds: 1),
      nearbyTtl: nearbyTtl,
    );
    return _LanPhone(settings, ledger, engine);
  }

  Future<List<NearbyPeer>> nearby() => engine.watchNearby().first;

  Future<List<NearbyPeer>> waitFor(bool Function(List<NearbyPeer>) test) =>
      engine.watchNearby().firstWhere(test).timeout(const Duration(seconds: 3));

  /// Names shown over [d].
  Future<Set<String>> namesOver(Duration d) async {
    final shown = <String>{for (final p in await nearby()) p.name};
    final sub = engine.watchNearby().listen((l) {
      for (final p in l) {
        shown.add(p.name);
      }
    });
    await Future<void>.delayed(d);
    await sub.cancel();
    return shown;
  }

  Future<void> dispose() async {
    await engine.dispose();
    await ledger.close();
  }
}

bool _has(List<NearbyPeer> l, String name) => l.any((p) => p.name == name);

void main() {
  final phones = <_LanPhone>[];
  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
  });

  Future<_LanPhone> phone(
    String letter,
    String name,
    MdnsBackend mdns, {
    String displayName = 'Alex',
  }) async {
    final p = await _LanPhone.create(
      letter,
      name,
      mdns,
      displayName: displayName,
    );
    phones.add(p);
    return p;
  }

  group('SYNC-R6-01 fix over LanTransport (127.0.0.1), goodbyes missed', () {
    test('two renames in a row show only the last name, in one row, '
        'and Sync reaches the renamed phone', () async {
      final air = FakeMdnsHub();
      final alex = await phone('a', 'Pixel 8', FakeMdns(air));
      final priya = await phone(
        'b',
        "Priya's Pixel",
        _OsCacheMdns(FakeMdns(air)),
        displayName: 'Priya',
      );
      final g = await alex.ledger.createGroup(
        const NewGroup(
          name: 'Goa trip',
          type: GroupType.trip,
          currency: 'INR',
          newMemberNames: ['Priya'],
        ),
      );
      await priya.ledger.registerJoinedGroup(
        g,
        (await alex.ledger.groupKeys())[g]!,
        'Goa trip',
      );
      await alex.engine.startHosting();
      await priya.engine.startDiscovery();
      await priya.waitFor((l) => _has(l, 'Pixel 8'));
      await alex.settings.setDeviceName("Alex's phone");
      await priya.waitFor((l) => _has(l, "Alex's phone"));
      await alex.settings.setDeviceName('Alex P');
      await priya.waitFor((l) => _has(l, 'Alex P'));
      final shown = await priya.namesOver(const Duration(milliseconds: 900));
      expect(shown, {'Alex P'});
      final rows = await priya.nearby();
      expect(rows, hasLength(1));
      final s = await priya.engine
          .syncWith(rows.single)
          .timeout(const Duration(seconds: 10));
      expect(s, isA<SyncSummary>());
    });

    test('a third phone stays listed next to the renamed one', () async {
      final air = FakeMdnsHub();
      final alex = await phone('a', 'Pixel 8', FakeMdns(air));
      final carol = await phone(
        'c',
        'Galaxy',
        FakeMdns(air),
        displayName: 'Carol',
      );
      final priya = await phone(
        'b',
        "Priya's Pixel",
        _OsCacheMdns(FakeMdns(air)),
        displayName: 'Priya',
      );
      await alex.engine.startHosting();
      await carol.engine.startHosting();
      await priya.engine.startDiscovery();
      await priya.waitFor((l) => _has(l, 'Pixel 8') && _has(l, 'Galaxy'));
      await alex.settings.setDeviceName("Alex's phone");
      await priya.waitFor((l) => _has(l, "Alex's phone"));
      final shown = await priya.namesOver(const Duration(milliseconds: 900));
      expect(shown, {"Alex's phone", 'Galaxy'});
      expect(await priya.nearby(), hasLength(2));
    });

    test('my own renamed service is never listed', () async {
      final air = FakeMdnsHub();
      final alex = await phone('a', 'Pixel 8', FakeMdns(air));
      final priya = await phone(
        'b',
        "Priya's Pixel",
        _OsCacheMdns(FakeMdns(air)),
        displayName: 'Priya',
      );
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      await priya.engine.startDiscovery();
      await priya.waitFor((l) => _has(l, 'Pixel 8'));
      await priya.settings.setDeviceName('Priya P');
      final shown = await priya.namesOver(const Duration(milliseconds: 900));
      expect(shown, {'Pixel 8'});
    });

    test(
      'SYNC-R8-01: a stale cached copy of the old name, resolved after '
      'the new one when discovery restarts, hides the renamed phone once '
      'the old record expires',
      () async {
        final air = FakeMdnsHub();
        final alex = await phone('a', 'Pixel 8', FakeMdns(air));
        final os = _OsCacheMdns(FakeMdns(air));
        final priya = await phone(
          'b',
          "Priya's Pixel",
          os,
          displayName: 'Priya',
        );
        await alex.engine.startHosting();
        await priya.engine.startDiscovery();
        await priya.waitFor((l) => _has(l, 'Pixel 8'));
        await alex.settings.setDeviceName("Alex's phone");
        await priya.waitFor((l) => _has(l, "Alex's phone"));
        // Priya leaves the Sync screen and comes back while her OS still
        // caches the old service (its goodbye was missed).
        await priya.engine.stopDiscovery();
        await priya.engine.startDiscovery();
        final before = await priya.namesOver(const Duration(milliseconds: 300));
        // The old record's TTL runs out: the OS reports 'Pixel 8' lost.
        // Alex is still advertising "Alex's phone" the whole time.
        os.expire('Pixel 8');
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final rows = await priya.nearby();
        expect(
          rows.map((p) => p.name),
          ["Alex's phone"],
          reason:
              'Alex is still advertising, but the stale "Pixel 8" '
              'sighting evicted the live service from the cache and its '
              'expiry removed the last entry: $rows (shown before the '
              'expiry: $before)',
        );
      },
      skip:
          'QA SYNC-R8-01: a stale old-name sighting evicts the live '
          'renamed service, so the old record\'s expiry hides a phone that '
          'is still advertising',
    );
  });

  group('LanTransport cache, scripted mDNS', () {
    late _ScriptedMdns mdns;
    late LanTransport t;
    const round = Duration(milliseconds: 15);

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

    test('a re-resolve of the new name (TXT update at a window change) '
        'keeps only the new name', () async {
      expect(
        await shownAfter([
          _resolved('Pixel 8'),
          _resolved("Alex's phone"),
          _resolved("Alex's phone", id: 'ffff0000'),
        ]),
        {"Alex's phone"},
      );
    });

    test(
      'SYNC-R8-01: new name, stale old name, then the old name\'s '
      'goodbye: the still-advertised new name stays listed',
      () async {
        expect(
          await shownAfter([
            _resolved("Alex's phone"),
            _resolved('Pixel 8'),
            ('Pixel 8', null),
          ]),
          {"Alex's phone"},
          reason: 'no goodbye was ever seen for "Alex\'s phone"',
        );
      },
      skip:
          'QA SYNC-R8-01: a stale old-name sighting evicts the live '
          'renamed service, so the old record\'s expiry hides a phone that '
          'is still advertising',
    );
  });
}
