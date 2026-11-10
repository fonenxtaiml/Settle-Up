// QA SYNC round 6: probes around the round 5 fix (SYNC-R5-01, a phone
// renamed while visible re-advertises its new name at once, and the busy
// refusal decides by advert id, not by name), through the real
// DefaultSyncEngine and Ledger over MemoryTransport and over the real
// LanTransport on 127.0.0.1 (mDNS faked).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/hosting_details.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/lan/support.dart';
import 'qa_phone.dart';

/// A [MemoryTransport] whose advert calls take [adDelay] and run one at a
/// time, as the real transports do (LAN, Nearby and BLE serialize them),
/// and that records what it advertised.
final class _Ads implements SyncTransport, HostingDetails {
  _Ads(this.inner);
  final MemoryTransport inner;
  Duration adDelay = Duration.zero;
  Duration? connectDelay;
  final List<AdvertiseInfo> adverts = [];
  bool advertising = false;
  Future<void> _queue = Future.value();

  Future<void> _serial(Future<void> Function() f) {
    final next = _queue.then((_) => f());
    _queue = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  Future<List<String>> hostAddresses() => inner.hostAddresses();
  @override
  Future<String?> wifiName() => inner.wifiName();
  @override
  bool isLinkHost(String address) => inner.isLinkHost(address);
  @override
  TransportKind get kind => inner.kind;
  @override
  Future<TransportAvailability> availability() => inner.availability();
  @override
  Future<TransportAvailability> requestPermissions() =>
      inner.requestPermissions();
  @override
  Future<void> startAdvertising(AdvertiseInfo info) => _serial(() async {
    if (adDelay > Duration.zero) await Future<void>.delayed(adDelay);
    adverts.add(info);
    advertising = true;
    await inner.startAdvertising(info);
  });
  @override
  Future<void> stopAdvertising() => _serial(() async {
    advertising = false;
    await inner.stopAdvertising();
  });
  @override
  Stream<FrameChannel> get inbound => inner.inbound;
  @override
  Stream<DiscoveredPeer> discover() => inner.discover();
  @override
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final d = connectDelay;
    if (d != null) await Future<void>.delayed(d);
    return inner.connect(peer, timeout: timeout);
  }

  @override
  Future<void> dispose() => inner.dispose();
}

/// mDNS whose browsers never hear a goodbye: a service that stopped stays
/// resolvable (a missed multicast goodbye on a busy hotspot; Android only
/// drops such a service when its record TTL runs out).
final class _NoGoodbyeMdns implements MdnsBackend {
  _NoGoodbyeMdns(this.inner);
  final FakeMdns inner;

  @override
  Future<void> advertise(MdnsAdvert advert) => inner.advertise(advert);
  @override
  Future<void> stopAdvertising() => inner.stopAdvertising();
  @override
  Stream<(String, MdnsSighting?)> browse() {
    final last = <String, MdnsSighting>{};
    late StreamController<(String, MdnsSighting?)> ctl;
    StreamSubscription<(String, MdnsSighting?)>? sub;
    ctl = StreamController(
      onListen: () {
        sub = inner.browse().listen((e) {
          final (name, s) = e;
          if (s != null) {
            last[name] = s;
            ctl.add(e);
          }
          // The goodbye (lost) never arrives.
        });
      },
      onCancel: () => sub?.cancel(),
    );
    return ctl.stream;
  }
}

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
    );
    return _LanPhone(settings, ledger, engine);
  }

  Future<void> dispose() async {
    await engine.dispose();
    await ledger.close();
  }
}

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];
  final ads = <String, List<_Ads>>{};

  setUp(() => hub = MemoryTransportHub());
  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
    ads.clear();
  });

  Future<Object> tap(QaPhone p, NearbyPeer to) =>
      p.engine.syncWith(to).then<Object>((s) => s, onError: (Object e) => e);

  Future<QaPhone> phone(String letter, String name) async {
    final p = await QaPhone.create(
      hub,
      letter,
      name,
      wrap: (t) {
        final w = _Ads(t);
        (ads[letter] ??= []).add(w);
        return w;
      },
    );
    phones.add(p);
    return p;
  }

  Future<List<NearbyPeer>> seeName(QaPhone who, String name) => who.engine
      .watchNearby()
      .firstWhere((l) => l.any((p) => p.name == name))
      .timeout(const Duration(seconds: 3));

  group('SYNC-R5-01 probes: renamed while visible', () {
    test('every transport re-advertises the new name; one row, same key, '
        'both transports', () async {
      final alex = await phone('a', 'Pixel 8');
      final priya = await phone('b', "Priya's Pixel");
      await alex.engine.startHosting();
      final before = await priya.find(alex, transports: 2);
      await alex.settings.setDeviceName("Alex's phone");
      await waitFor(() async {
        final l = await priya.engine.watchNearby().first;
        return l.length == 1 &&
            l.single.name == "Alex's phone" &&
            l.single.transports.length == 2;
      });
      final list = await priya.engine.watchNearby().first;
      expect(list.single.key, before.key);
      expect(list.single.advertId, before.advertId);
      for (final t in ads['a']!) {
        expect(t.adverts.last.deviceName, "Alex's phone");
        expect(t.adverts.last.advertId, t.adverts.first.advertId);
      }
    });

    test('a rename while hosting is still starting (slow advert) ends '
        'with the new name advertised', () async {
      final alex = await phone('a', 'Pixel 8');
      for (final t in ads['a']!) {
        t.adDelay = const Duration(milliseconds: 200);
      }
      final starting = alex.engine.startHosting();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await alex.settings.setDeviceName("Alex's phone");
      final host = await starting;
      await waitFor(
        () => ads['a']!.every(
          (t) =>
              t.adverts.isNotEmpty &&
              t.adverts.last.deviceName == "Alex's phone",
        ),
        timeout: const Duration(seconds: 3),
      );
      for (final t in ads['a']!) {
        expect(t.adverts.last.deviceName, "Alex's phone");
      }
      // The link the host screen shows carries the new name too.
      await waitFor(
        () =>
            ConnectLink.tryParse(alex.engine.status.host!.connectLink)!
                .deviceName ==
            "Alex's phone",
      );
      expect(host.expiresAt, alex.engine.status.host!.expiresAt);
    });

    test('three quick renames: the last name is what stays advertised, in '
        'order', () async {
      final alex = await phone('a', 'Pixel 8');
      final priya = await phone('b', "Priya's Pixel");
      await alex.engine.startHosting();
      await priya.find(alex);
      for (final t in ads['a']!) {
        t.adDelay = const Duration(milliseconds: 80);
      }
      await alex.settings.setDeviceName('One');
      await alex.settings.setDeviceName('Two');
      await alex.settings.setDeviceName('Three');
      await seeName(priya, 'Three');
      await Future<void>.delayed(const Duration(milliseconds: 600));
      for (final t in ads['a']!) {
        expect(t.adverts.last.deviceName, 'Three');
      }
      final l = await priya.engine.watchNearby().first;
      expect(l.single.name, 'Three');
      expect(
        ConnectLink.tryParse(alex.engine.status.host!.connectLink)!.deviceName,
        'Three',
      );
    });

    test('rename, then visibility off while the re-advertise is in flight: '
        'nothing advertises afterwards', () async {
      final alex = await phone('a', 'Pixel 8');
      await alex.engine.startHosting();
      for (final t in ads['a']!) {
        t.adDelay = const Duration(milliseconds: 150);
      }
      await alex.settings.setDeviceName("Alex's phone");
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await alex.engine.stopHosting();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      for (final t in ads['a']!) {
        expect(t.advertising, isFalse, reason: '${t.kind}');
      }
      expect(alex.engine.status.host, isNull);
      // A later rename advertises nothing.
      final n = [for (final t in ads['a']!) t.adverts.length];
      await alex.settings.setDeviceName('Later');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect([for (final t in ads['a']!) t.adverts.length], n);
    });

    test('visibility off and on again: one rename re-advertises once per '
        'transport (no rename watch left from the first hosting)', () async {
      final alex = await phone('a', 'Pixel 8');
      await alex.engine.startHosting();
      await alex.engine.stopHosting();
      await alex.engine.startHosting();
      await alex.engine.stopHosting();
      await alex.engine.startHosting();
      final n = [for (final t in ads['a']!) t.adverts.length];
      await alex.settings.setDeviceName("Alex's phone");
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        [for (final t in ads['a']!) t.adverts.length],
        [for (final c in n) c + 1],
      );
    });

    test(
      'hosting expiry still ends visibility on time after a rename',
      () async {
        final alex = await phone('a', 'Pixel 8');
        await alex.engine.startHosting(
          duration: const Duration(milliseconds: 700),
        );
        await alex.settings.setDeviceName("Alex's phone");
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(alex.engine.status.host, isNotNull);
        await Future<void>.delayed(const Duration(milliseconds: 900));
        expect(alex.engine.status.host, isNull);
        for (final t in ads['a']!) {
          expect(t.advertising, isFalse);
        }
      },
    );

    test('a rename in the middle of a running Sync: the Sync completes and '
        'the data converges', () async {
      final alex = await phone('a', 'Pixel 8');
      final priya = await phone('b', "Priya's Pixel");
      final seed = await alex.seedGroup(expenses: 2);
      await priya.join(alex, seed.g);
      await alex.addExpenses(seed, 300);
      hub.latency = const Duration(milliseconds: 2);
      await alex.engine.startHosting();
      final toAlex = await priya.find(alex);
      final f = tap(priya, toAlex);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await alex.settings.setDeviceName("Alex's phone");
      final r = await f.timeout(const Duration(seconds: 20));
      expect(r, isA<SyncSummary>(), reason: '$r');
      await waitFor(() => priya.opCount(seed.g) == alex.opCount(seed.g));
      expect(priya.canonical, alex.canonical);
    });

    for (final first in ['a', 'b']) {
      test('mutual Sync right after the rename (stale advert), '
          '${first == 'a' ? 'the renamed phone' : 'the other phone'} taps '
          'first: both complete', () async {
        final alex = await phone('a', 'Pixel 8');
        final priya = await phone('b', "Priya's Pixel");
        final seed = await alex.seedGroup(expenses: 2);
        await priya.join(alex, seed.g);
        for (final t in ads['b']!) {
          t.connectDelay = const Duration(seconds: 3);
        }
        await alex.engine.startHosting();
        await priya.engine.startHosting();
        final stale = await priya.find(alex);
        await alex.settings.setDeviceName("Alex's phone");
        final toPriya = await alex.find(priya);
        final Future<Object> fp, fa;
        if (first == 'b') {
          fp = tap(priya, stale);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          fa = tap(alex, toPriya);
        } else {
          fa = tap(alex, toPriya);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          fp = tap(priya, stale);
        }
        final results = await Future.wait([fa, fp])
            .timeout(const Duration(seconds: 20));
        expect(results, everyElement(isA<SyncSummary>()), reason: '$results');
        expect(priya.opCount(seed.g), alex.opCount(seed.g));
      });
    }

    test(
      'a third phone that is not being dialed is told "with someone '
      'else" at once even when it shares the dialed phone\'s new name',
      () async {
        final alex = await phone('a', 'Pixel 8');
        final priya = await phone('b', "Priya's Pixel");
        final carol = await phone('c', 'Pixel 8');
        final seed = await alex.seedGroup(expenses: 2);
        await priya.join(alex, seed.g);
        await carol.join(alex, seed.g);
        for (final t in ads['b']!) {
          t.connectDelay = const Duration(seconds: 3);
        }
        await alex.engine.startHosting();
        await priya.engine.startHosting();
        await carol.engine.startHosting();
        final toAlex = await priya.find(alex);
        await alex.settings.setDeviceName("Carol's phone");
        await carol.settings.setDeviceName("Carol's phone");
        final toPriya = await carol.find(priya);
        final fp = tap(priya, toAlex);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final w = Stopwatch()..start();
        final c = await tap(
          carol,
          toPriya,
        ).timeout(const Duration(seconds: 15));
        expect(
          c,
          isA<SyncException>().having(
            (e) => e.message,
            'message',
            endsWith('Starting its own sync with someone else'),
          ),
        );
        expect(w.elapsed, lessThan(const Duration(milliseconds: 2800)));
        expect(
          await fp.timeout(const Duration(seconds: 10)),
          isA<SyncSummary>(),
        );
      },
    );
  });

  group('SYNC-R5-01 probes over LanTransport (127.0.0.1)', () {
    final lan = <_LanPhone>[];
    tearDown(() async {
      for (final p in lan) {
        await p.dispose();
      }
      lan.clear();
    });

    Future<List<NearbyPeer>> names(_LanPhone p) => p.engine.watchNearby().first;

    test('the renamed phone shows under its new name, in one row', () async {
      final air = FakeMdnsHub();
      final alex = await _LanPhone.create('a', 'Pixel 8', FakeMdns(air));
      final priya = await _LanPhone.create(
        'b',
        "Priya's Pixel",
        FakeMdns(air),
        displayName: 'Priya',
      );
      lan.addAll([alex, priya]);
      await alex.engine.startHosting();
      await priya.engine.startDiscovery();
      await priya.engine
          .watchNearby()
          .firstWhere((l) => l.any((p) => p.name == 'Pixel 8'))
          .timeout(const Duration(seconds: 3));
      await alex.settings.setDeviceName("Alex's phone");
      await priya.engine
          .watchNearby()
          .firstWhere((l) => l.any((p) => p.name == "Alex's phone"))
          .timeout(const Duration(seconds: 3));
      // Stays so over several re-discovery rounds.
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final l = await names(priya);
        expect(l, hasLength(1));
        expect(l.single.name, "Alex's phone");
      }
    });

    test('SYNC-R6-01: after a rename whose mDNS goodbye is missed, the '
        'Nearby row flips between the old and the new name', () async {
      final air = FakeMdnsHub();
      final alex = await _LanPhone.create('a', 'Pixel 8', FakeMdns(air));
      final priya = await _LanPhone.create(
        'b',
        "Priya's Pixel",
        _NoGoodbyeMdns(FakeMdns(air)),
        displayName: 'Priya',
      );
      lan.addAll([alex, priya]);
      await alex.engine.startHosting();
      await priya.engine.startDiscovery();
      await priya.engine
          .watchNearby()
          .firstWhere((l) => l.any((p) => p.name == 'Pixel 8'))
          .timeout(const Duration(seconds: 3));
      await alex.settings.setDeviceName("Alex's phone");
      await priya.engine
          .watchNearby()
          .firstWhere((l) => l.any((p) => p.name == "Alex's phone"))
          .timeout(const Duration(seconds: 3));
      final shown = <String>{};
      final sub = priya.engine.watchNearby().listen((l) {
        for (final p in l) {
          shown.add(p.name);
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await sub.cancel();
      final l = await names(priya);
      expect(l, hasLength(1));
      expect(
        shown,
        {"Alex's phone"},
        reason:
            'the old service (same address, same advert id) is still '
            're-emitted every rediscover round, so the row shows: $shown',
      );
    }, skip: 'SYNC-R6-01');
  });
}
