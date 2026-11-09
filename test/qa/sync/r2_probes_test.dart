// QA SYNC round 2: probes around the round 1 fixes (SYNC-R1-01..07):
// variations and neighbouring cases of each repro, through the real
// DefaultSyncEngine and Ledger over MemoryTransport and loopback LAN.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/crypto/tokens.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/ble/ble_info.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/lan/support.dart';
import '../../sync/support/phone.dart' show groupIdOf, groupKeyOf;
import 'qa_phone.dart';

/// Returns [first] once (the device id), then delegates.
final class _FirstIdGen implements IdGenerator {
  _FirstIdGen(this.first, this.rest);
  final String first;
  final IdGenerator rest;
  bool _used = false;

  @override
  String newId() {
    if (_used) return rest.newId();
    _used = true;
    rest.newId();
    return first;
  }
}

/// A phone on the real LanTransport (127.0.0.1, fake mDNS) with a chosen
/// device id.
final class _LanPhone {
  _LanPhone(this.ledger, this.engine);
  final Ledger ledger;
  final DefaultSyncEngine engine;

  static Future<_LanPhone> create(
    String letter,
    String name,
    FakeMdnsHub hub,
    String deviceId,
  ) async {
    final store = MemoryOpStore();
    await store.open();
    final ids = _FirstIdGen(deviceId, PhoneIds(letter));
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: name,
      ids: ids,
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(displayName: name, homeCurrency: 'INR');
    final ledger = await Ledger.open(
      store: store,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
    );
    final lan = LanTransport(
      port: 0,
      mdns: FakeMdns(hub),
      network: FakeLanNetwork(),
      bindAddress: InternetAddress.loopbackIPv4,
      rediscoverInterval: const Duration(milliseconds: 150),
      probeInterval: const Duration(milliseconds: 150),
      firstFrameTimeout: const Duration(seconds: 2),
    );
    final engine = DefaultSyncEngine(
      store: ledger,
      transports: [lan],
      timings: fastTimings,
      linkConnectTimeout: const Duration(seconds: 1),
    );
    return _LanPhone(ledger, engine);
  }

  Map<String, Object?> get canonical => ledger.current.state.toCanonicalJson();

  Future<void> dispose() async {
    await engine.dispose();
    await ledger.close();
  }
}

/// Two UUIDv7 ids minted a few ms apart (same first 8 hex chars).
Future<(String, String)> _samePrefixIds() async {
  const gen = UuidV7Generator();
  for (;;) {
    final a = gen.newId();
    await Future<void>.delayed(const Duration(milliseconds: 3));
    final b = gen.newId();
    if (a.substring(0, 8) == b.substring(0, 8) && a != b) return (a, b);
  }
}

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(
    String letter,
    String name, {
    SkewedClock? clock,
    SyncClock? engineClock,
    SessionTimings timings = fastTimings,
    String? deviceId,
    SyncTransport Function(MemoryTransport t)? wrap,
  }) async {
    final p = await QaPhone.create(
      hub,
      letter,
      name,
      clock: clock,
      engineClock: engineClock,
      timings: timings,
      deviceId: deviceId,
      wrap: wrap,
    );
    phones.add(p);
    return p;
  }

  setUp(() => hub = MemoryTransportHub());
  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
  });

  // ------------------------------------------------------------ R1-06 --

  group('R1-06 probes: self-detection by advert id', () {
    test('LAN loopback: same-prefix device ids, both phones hosting and '
        'discovering, each lists only the other and they sync', () async {
      final mdns = FakeMdnsHub();
      final (idA, idB) = await _samePrefixIds();
      final alex = await _LanPhone.create('a', "Alex's Pixel", mdns, idA);
      final priya = await _LanPhone.create('b', "Priya's Pixel", mdns, idB);
      addTearDown(() async {
        await alex.dispose();
        await priya.dispose();
      });
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
      await priya.engine.startHosting();
      await alex.engine.startDiscovery();
      await priya.engine.startDiscovery();

      Future<List<NearbyPeer>> seen(_LanPhone p, String other) => p.engine
          .watchNearby()
          .firstWhere((l) => l.any((x) => x.name == other))
          .timeout(const Duration(seconds: 4));
      final byAlex = await seen(alex, "Priya's Pixel");
      final byPriya = await seen(priya, "Alex's Pixel");
      // Give the own mDNS answer time to show up too, if it would.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final alexList = await alex.engine.watchNearby().first;
      final priyaList = await priya.engine.watchNearby().first;
      expect(alexList.map((p) => p.name), [
        "Priya's Pixel",
      ], reason: 'Alex lists itself or misses Priya');
      expect(priyaList.map((p) => p.name), ["Alex's Pixel"]);
      expect(byAlex.single.sharedGroupIds, [g]);
      expect(byPriya.single.sharedGroupIds, [g]);
      await alex.engine.syncWith(alexList.single);
      expect(priya.canonical, alex.canonical);
    });

    test(
      'advert id rotation at a window boundary keeps one row with the same '
      'key, still shared, and the row found before the rotation still syncs',
      () async {
        // Both phones 1.5 s before the end of a token window.
        final now = DateTime.now().toUtc();
        final intoWindow = now.millisecondsSinceEpoch % 600000;
        final offset = Duration(milliseconds: 598500 - intoWindow);
        final alex = await phone(
          'a',
          "Alex's Pixel",
          clock: SkewedClock(offset),
        );
        final priya = await phone(
          'b',
          "Priya's Pixel",
          clock: SkewedClock(offset),
        );
        final seed = await alex.seedGroup(expenses: 2);
        await priya.join(alex, seed.g);
        await priya.engine.startHosting();
        final before = await priya.engine.startHosting();
        expect(before, isNotNull);
        final peer = await alex.find(priya, transports: 2);
        final idBefore = peer.advertId;
        expect(idBefore, isNotNull);
        // Wait for Priya to re-advertise in the next window.
        final rotated = await alex.engine
            .watchNearby()
            .firstWhere((l) => l.any((p) => p.advertId != idBefore))
            .timeout(const Duration(seconds: 6));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final list = await alex.engine.watchNearby().first;
        expect(list, hasLength(1), reason: 'duplicate rows: $list / $rotated');
        expect(list.single.key, peer.key);
        expect(list.single.transports, {TransportKind.lan, TransportKind.ble});
        expect(list.single.sharedGroupIds, [seed.g]);
        final s = await alex.engine.syncWith(peer);
        expect(s.sentOps, alex.opCount(seed.g));
        expect(priya.canonical, alex.canonical);
      },
    );
  });

  // ------------------------------------------------------------ R1-02 --

  group('R1-02 probes: discovery skew matrix', () {
    for (final into in const [
      Duration.zero,
      Duration(minutes: 5),
      Duration(minutes: 9, seconds: 59),
    ]) {
      for (final skew in const [
        Duration(minutes: 9),
        Duration(minutes: 11),
        Duration(minutes: -9),
        Duration(minutes: -11),
        Duration(hours: 23),
        Duration(hours: -23),
        Duration(hours: 47),
        Duration(hours: -47),
      ]) {
        test(
          'scanner ${into.inSeconds}s into its window, host $skew',
          () async {
            final base = DateTime.utc(2026, 11, 9, 12).add(into);
            final alex = await phone(
              'a',
              "Alex's Pixel",
              engineClock: FixedClock(base),
            );
            final priya = await phone(
              'b',
              "Priya's Pixel",
              engineClock: FixedClock(base.add(skew)),
            );
            final seed = await alex.seedGroup(expenses: 1);
            await priya.join(alex, seed.g);
            await priya.engine.startHosting();
            final peer = await alex.find(priya);
            expect(peer.sharedGroupIds, [seed.g]);
          },
        );
      }
    }

    test('joining a group while discovering a skewed host (+2 h) updates the '
        'row to shared without restarting discovery', () async {
      final base = DateTime.utc(2026, 11, 9, 12, 3);
      final priya = await phone(
        'b',
        "Priya's Pixel",
        engineClock: FixedClock(base.add(const Duration(hours: 2))),
      );
      final alex = await phone(
        'a',
        "Alex's Pixel",
        engineClock: FixedClock(base),
      );
      final seed = await priya.seedGroup(expenses: 1, others: ['Alex']);
      await priya.engine.startHosting();
      final before = await alex.find(priya);
      expect(before.sharedGroupIds, isEmpty);
      await alex.join(priya, seed.g);
      final after = await alex.engine
          .watchNearby()
          .firstWhere((l) => l.any((p) => p.sharedGroupIds.isNotEmpty))
          .timeout(const Duration(seconds: 4));
      expect(after.single.sharedGroupIds, [seed.g]);
    });
  });

  // ------------------------------------------------------------ R1-03 --

  group('R1-03 probes: both phones tap Sync at once', () {
    for (final (latency, stagger, lowerFirst) in const [
      (0, 0, true),
      (30, 0, false),
      (30, 5, true),
      (30, 5, false),
      (30, 25, true),
      (30, 25, false),
      (30, 60, true),
      (30, 60, false),
      (200, 0, true),
      (200, 100, false),
    ]) {
      test(
        'latency ${latency}ms, second tap after ${stagger}ms, '
        '${lowerFirst ? 'lower' : 'higher'} device id taps first: both '
        'calls succeed, one completed record each, engines free afterwards',
        () async {
          hub.latency = Duration(milliseconds: latency);
          final alex = await phone('a', "Alex's Pixel");
          final priya = await phone('b', "Priya's Pixel");
          expect(alex.deviceId.compareTo(priya.deviceId), lessThan(0));
          final seed = await alex.seedGroup(expenses: 3);
          await priya.join(alex, seed.g);
          await syncByLink(priya, alex);
          await alex.addExpense(
            seed.g,
            payer: seed.a,
            owers: [seed.a, seed.b],
            description: 'From Alex',
          );
          await priya.addExpense(
            seed.g,
            payer: seed.b,
            owers: [seed.a, seed.b],
            description: 'From Priya',
          );
          final ra0 = (await alex.records()).length;
          final rp0 = (await priya.records()).length;
          await alex.engine.startHosting();
          await priya.engine.startHosting();
          final toPriya = await alex.find(priya);
          final toAlex = await priya.find(alex);

          Future<Object> tap(QaPhone p, NearbyPeer to) => p.engine
              .syncWith(to)
              .then<Object>((s) => s, onError: (Object e) => e);
          final first = lowerFirst ? alex : priya;
          final second = lowerFirst ? priya : alex;
          final f1 = tap(first, lowerFirst ? toPriya : toAlex);
          await Future<void>.delayed(Duration(milliseconds: stagger));
          final f2 = tap(second, lowerFirst ? toAlex : toPriya);
          final results = await Future.wait([f1, f2])
              .timeout(const Duration(seconds: 10));
          expect(
            results.whereType<SyncSummary>(),
            hasLength(2),
            reason: 'results: $results',
          );
          expect(priya.canonical, alex.canonical);
          await waitFor(
            () =>
                alex.engine.status.session is! SessionActive &&
                priya.engine.status.session is! SessionActive,
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final ra = (await alex.records()).take(
            (await alex.records()).length - ra0,
          );
          final rp = (await priya.records()).take(
            (await priya.records()).length - rp0,
          );
          expect(
            ra.map((r) => r.outcome),
            [SyncOutcome.completed],
            reason: 'Alex records: ${ra.map((r) => '${r.outcome} ${r.error}')}',
          );
          expect(
            rp.map((r) => r.outcome),
            [SyncOutcome.completed],
            reason:
                'Priya records: ${rp.map((r) => '${r.outcome} ${r.error}')}',
          );
          expect(alex.engine.status.session, isA<SessionCompleted>());
          expect(priya.engine.status.session, isA<SessionCompleted>());
          // Both engines are free again.
          await alex.addExpense(
            seed.g,
            payer: seed.a,
            owers: [seed.a, seed.b],
            description: 'Later',
          );
          final again = await alex.engine.syncWith(await alex.find(priya));
          expect(again.sentOps, 1);
          await waitFor(() => priya.engine.status.session is! SessionActive);
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final back = await priya.engine.syncWith(await priya.find(alex));
          expect(back.sentOps + back.receivedOps, 0);
        },
      );
    }

    for (final delayMs in const [500, 1500]) {
      test('mutual tap where the higher id phone\'s connect takes ${delayMs}ms '
          '(slow Nearby dial): at least one succeeds and nobody is told '
          'another phone is syncing', () async {
        final alex = await phone('a', "Alex's Pixel");
        final priya = await phone(
          'b',
          "Priya's Pixel",
          wrap: (t) => SlowConnectTransport(t, Duration(milliseconds: delayMs)),
        );
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
        final results = await Future.wait([fa, fp])
            .timeout(const Duration(seconds: 15));
        expect(
          results.whereType<SyncSummary>(),
          isNotEmpty,
          reason: 'results: $results',
        );
        for (final r in results.whereType<SyncException>()) {
          expect(
            r.message,
            isNot(contains('another phone')),
            reason: 'results: $results',
          );
        }
        expect(priya.canonical, alex.canonical);
      });
    }

    test(
      'mutual tap while a third phone also syncs with the lower one: no '
      'hang, the pair converges, and every engine is free afterwards',
      () async {
        hub.latency = const Duration(milliseconds: 20);
        final alex = await phone('a', "Alex's Pixel");
        final priya = await phone('b', "Priya's Pixel");
        final ravi = await phone('c', "Ravi's Galaxy");
        final seed = await alex.seedGroup(expenses: 2);
        await priya.join(alex, seed.g);
        await ravi.join(alex, seed.g);
        for (final p in [alex, priya, ravi]) {
          await p.engine.startHosting();
        }
        final aToP = await alex.find(priya);
        final pToA = await priya.find(alex);
        final rToA = await ravi.find(alex);
        Future<Object> tap(QaPhone p, NearbyPeer to) => p.engine
            .syncWith(to)
            .then<Object>((s) => s, onError: (Object e) => e);
        final results = await Future.wait([
          tap(alex, aToP),
          tap(priya, pToA),
          tap(ravi, rToA),
        ]).timeout(const Duration(seconds: 15));
        expect(
          results.take(2).whereType<SyncSummary>(),
          isNotEmpty,
          reason: '$results',
        );
        expect(priya.canonical, alex.canonical);
        await waitFor(
          () => [
            alex,
            priya,
            ravi,
          ].every((p) => p.engine.status.session is! SessionActive),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await syncByLink(ravi, alex);
        expect(ravi.canonical, alex.canonical);
        await syncByLink(priya, ravi);
      },
    );
  });

  // ------------------------------------------------------------ R1-04 --

  group('R1-04 probes: link drop at every frame', () {
    for (var n = 1; n <= 12; n++) {
      test('drop after $n frames: a side that records completed holds all '
          'data, no double apply, and the next session completes', () async {
        final alex = await phone('a', "Alex's Pixel");
        final priya = await phone('b', "Priya's Pixel");
        final seed = await alex.seedGroup(expenses: 3);
        await priya.join(alex, seed.g);
        alex.lan.dropAfterFrames = n;
        final host = await priya.engine.startHosting();
        Object? first;
        try {
          first = await alex.engine.syncWithLink(host.connectLink);
        } on SyncException catch (e) {
          first = e;
        }
        await waitFor(
          () async =>
              (await priya.records()).isNotEmpty &&
              priya.engine.status.session is! SessionActive,
        );
        await Future<void>.delayed(const Duration(milliseconds: 600));
        final ra = await alex.records();
        final rp = await priya.records();
        final complete = priya.opCount(seed.g) == alex.opCount(seed.g);
        for (final (who, rs) in [('Alex', ra), ('Priya', rp)]) {
          for (final r in rs) {
            if (r.outcome == SyncOutcome.completed) {
              expect(
                complete,
                isTrue,
                reason:
                    '$who recorded completed without the data '
                    '(first: $first)',
              );
            }
          }
        }
        if (first is SyncSummary) {
          expect(complete, isTrue);
        }
        alex.lan.dropAfterFrames = null;
        final s = await alex.engine.syncWithLink(host.connectLink);
        expect(priya.canonical, alex.canonical);
        expect(priya.opCount(seed.g), alex.opCount(seed.g));
        expect(s.sentOps, complete ? 0 : greaterThan(0));
        expect(
          alex.ledger.current.ops.map((o) => o.id).toSet(),
          hasLength(alex.totalOps),
        );
      });
    }
  });

  // ------------------------------------------------------------ R1-05 --

  test('R1-05 probe: after the same-phone retry replaces the dead session, the '
      'host ends completed, records the stale one as not completed, and holds '
      'every op once', () async {
    CuttableTransport? alexLan;
    final alex = await phone(
      'a',
      "Alex's Pixel",
      wrap: (t) {
        if (t.kind != TransportKind.lan) return t;
        return alexLan = CuttableTransport(t);
      },
    );
    final priya = await phone(
      'b',
      "Priya's Pixel",
      timings: const SessionTimings(),
    );
    final seed = await alex.seedGroup(expenses: 0);
    await priya.join(alex, seed.g);
    await alex.addExpenses(seed, 300);
    hub.latency = const Duration(milliseconds: 10);
    await priya.engine.startHosting();
    final peer = await alex.find(priya, transports: 2);
    final first = alex.engine
        .syncWith(peer)
        .then<Object?>((s) => s, onError: (Object e) => e);
    await waitFor(() => priya.engine.status.session is SessionActive);
    alexLan!.cut();
    await alex.engine.cancel();
    await first;
    alex.lan.failConnect = true;
    final retry = await alex.engine.syncWith(await alex.find(priya));
    expect(retry, isA<SyncSummary>());
    expect(priya.canonical, alex.canonical);
    await waitFor(() async => (await priya.records()).length >= 2);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final rp = await priya.records();
    expect(
      rp.where((r) => r.outcome == SyncOutcome.completed),
      hasLength(1),
      reason: '${rp.map((r) => '${r.outcome} ${r.error}')}',
    );
    expect(priya.engine.status.session, isA<SessionCompleted>());
    expect(
      priya.ledger.current.ops.map((o) => o.id).toSet(),
      hasLength(priya.totalOps),
    );
    expect(priya.opCount(seed.g), alex.opCount(seed.g));
  });

  // ------------------------------------------------------------ R1-01 --

  group('R1-01 probes: other writes after syncing with a skewed phone', () {
    for (final (label, skew) in const [
      ('+2 h', Duration(hours: 2)),
      ('-1 day', Duration(days: -1)),
      ('+6 days', Duration(days: 6)),
    ]) {
      test('$label: delete, restore, member rename and group rename by the '
          'phone behind take effect and win on both', () async {
        final alex = await phone('a', "Alex's Pixel");
        final priya = await phone(
          'b',
          "Priya's Pixel",
          clock: SkewedClock(skew),
        );
        final seed = await alex.seedGroup(expenses: 2);
        await priya.join(alex, seed.g);
        await syncByLink(priya, alex);
        final ahead = skew.isNegative ? alex : priya;
        final behind = skew.isNegative ? priya : alex;
        final es = behind.state.groups[seed.g]!.expenses.keys.toList()..sort();

        // The phone ahead writes everything; the phone behind receives.
        await ahead.edit(es[0], description: 'Ahead edit');
        await ahead.ledger.deleteExpense(es[1]);
        await ahead.ledger.renameMember(seed.g, seed.b, 'Priya Ahead');
        await ahead.ledger.updateGroup(
          seed.g,
          const GroupPatch(name: 'Ahead name'),
        );
        await syncByLink(behind, ahead);

        await behind.ledger.deleteExpense(es[0]);
        await behind.ledger.restoreExpense(es[1]);
        await behind.ledger.renameMember(seed.g, seed.b, 'Priya Fixed');
        await behind.ledger.updateGroup(
          seed.g,
          const GroupPatch(name: 'Fixed name'),
        );
        void check(QaPhone p, String who) {
          final g = p.state.groups[seed.g]!;
          expect(g.group!.name, 'Fixed name', reason: who);
          expect(g.members[seed.b]!.displayName, 'Priya Fixed', reason: who);
          expect(
            p.state.expense(es[0])?.isDeleted ?? true,
            isTrue,
            reason: '$who: delete by the phone behind',
          );
          expect(
            p.state.expense(es[1])!.isDeleted,
            isFalse,
            reason: '$who: restore by the phone behind',
          );
        }

        check(behind, 'behind, right after saving');
        await syncByLink(behind, ahead);
        check(ahead, 'ahead, after sync');
        expect(ahead.canonical, behind.canonical);
      });
    }
  });

  // ---------------------------------------------- R1-07 neighbourhood --

  group('R1-07 probes: more groups than an advert holds', () {
    // A heavier user: 3 trips + many 1:1 friend groups.
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
      ('nearby', 24),
      ('ble', 48),
      ('lan', 48),
    ]) {
      test('over $name, $groups groups (the advert limit) never hide the '
          'shared one', () async {
        expect(await missed(groups, decoders[name]!), 0);
      });
    }
  });
}
