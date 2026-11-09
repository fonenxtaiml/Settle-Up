// QA SYNC-R1: repro tests for defects found in round 1. Each one FAILS on
// the code under test and is skipped with its finding id so the suite
// stays green. Remove the skip once the fix lands.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'package:settle_up/sync/crypto/tokens.dart';
import 'package:settle_up/sync/transport/ble/ble_info.dart';
import 'package:settle_up/sync/transport/lan/mdns.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/support/phone.dart' show groupIdOf, groupKeyOf;
import 'qa_phone.dart';

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(
    String letter,
    String name, {
    SkewedClock? clock,
  }) async {
    final p = await QaPhone.create(hub, letter, name, clock: clock);
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

  group('SYNC-R1-01: edits after syncing with a skewed clock', () {
    for (final (label, skew) in [
      ('+2 h', const Duration(hours: 2)),
      ('-1 day', const Duration(days: -1)),
    ]) {
      test(
        'Priya $label: the next edit of a field the other phone wrote '
        'last takes effect',
        () async {
          final alex = await phone('a', "Alex's Pixel");
          final priya = await phone(
            'b',
            "Priya's Pixel",
            clock: SkewedClock(skew),
          );
          final seed = await alex.seedGroup(expenses: 1);
          await priya.join(alex, seed.g);
          await syncByLink(priya, alex);
          final e = alex.state.groups[seed.g]!.expenses.keys.single;

          // The phone whose clock is AHEAD writes; the other one receives.
          final ahead = skew.isNegative ? alex : priya;
          final behind = skew.isNegative ? priya : alex;
          await ahead.edit(e, description: 'Written by the phone ahead');
          await syncByLink(behind, ahead);
          expect(behind.ledger.clockSkewDetected, isTrue);

          // The user of the phone behind fixes the description and saves.
          await behind.edit(e, description: 'Fixed later');
          expect(
            behind.state.expense(e)!.description,
            'Fixed later',
            reason: 'a save on this phone must not be a silent no-op',
          );
          await syncByLink(behind, ahead);
          expect(ahead.state.expense(e)!.description, 'Fixed later');
        },
        skip:
            'QA SYNC-R1-01: after syncing with a phone whose clock is '
            'more than 1 h ahead, edits on the other phone are silent no-ops',
      );
    }
  });

  group('SYNC-R1-02: discovery under clock skew', () {
    for (final (label, skew) in [
      ('+2 h', const Duration(hours: 2)),
      ('-1 day', const Duration(days: -1)),
      ('+6 min', const Duration(minutes: 6)),
    ]) {
      test(
        'host clock $label: a nearby member is still shown as sharing the '
        'group',
        () async {
          // Freeze the scanner 9 minutes into a 10-minute token window so a
          // few minutes of skew crosses the window boundary.
          final base = DateTime.utc(2026, 11, 9, 12, 9);
          final alexClock = FixedClock(base);
          final priyaClock = FixedClock(base.add(skew));
          final alex = await QaPhone.create(
            hub,
            'a',
            "Alex's Pixel",
            engineClock: alexClock,
          );
          final priya = await QaPhone.create(
            hub,
            'b',
            "Priya's Pixel",
            engineClock: priyaClock,
          );
          phones.addAll([alex, priya]);
          final seed = await alex.seedGroup(expenses: 1);
          await priya.join(alex, seed.g);

          await priya.engine.startHosting();
          final peer = await alex.find(priya);
          expect(
            peer.sharedGroupIds,
            [seed.g],
            reason:
                'the Sync screen shows "Pair" and refuses to sync a peer '
                'without shared groups',
          );
        },
        skip:
            'QA SYNC-R1-02: discovery tokens only match within one '
            '10-minute window, so a skewed clock hides shared groups',
      );
    }
  });

  test(
    'SYNC-R1-03: both phones tap Sync on each other at once; at least one '
    'session succeeds',
    () async {
      hub.latency = const Duration(milliseconds: 30);
      final alex = await phone('a', "Alex's Pixel");
      final priya = await phone('b', "Priya's Pixel");
      final seed = await alex.seedGroup(expenses: 3);
      await priya.join(alex, seed.g);
      await alex.engine.startHosting();
      await priya.engine.startHosting();
      final toPriya = await alex.find(priya);
      final toAlex = await priya.find(alex);

      final results = await Future.wait([
        alex.engine
            .syncWith(toPriya)
            .then<Object>((s) => s, onError: (Object e) => e),
        priya.engine
            .syncWith(toAlex)
            .then<Object>((s) => s, onError: (Object e) => e),
      ]);
      expect(
        results.whereType<SyncSummary>(),
        isNotEmpty,
        reason: 'both phones failed with: $results',
      );
      expect(priya.canonical, alex.canonical);
    },
    skip:
        'QA SYNC-R1-03: simultaneous mutual sync makes both phones reject '
        'each other as busy',
  );

  test(
    'SYNC-R1-04: the responder records a complete exchange as completed even '
    'if the link drops right after the initiator says BYE',
    () async {
      final alex = await phone('a', "Alex's Pixel");
      final priya = await phone('b', "Priya's Pixel");
      final seed = await alex.seedGroup(expenses: 3);
      await priya.join(alex, seed.g);
      // A 12-frame session: HELLO x2, AUTH x2, VV x2, DONE(R), OPS, DONE(I),
      // ACK, BYE(I), BYE(R). Drop right after BYE(I) is delivered.
      alex.lan.dropAfterFrames = 11;
      final host = await priya.engine.startHosting();
      final summary = await alex.engine.syncWithLink(host.connectLink);
      expect(summary.sentOps, 6);
      expect(priya.canonical, alex.canonical);
      expect((await alex.records()).single.outcome, SyncOutcome.completed);
      await waitFor(() async => (await priya.records()).isNotEmpty);
      final r = (await priya.records()).single;
      expect(
        r.outcome,
        SyncOutcome.completed,
        reason:
            'every op was received and ACKed and the peer recorded '
            'completed; got ${r.outcome} (${r.error})',
      );
      expect(priya.engine.status.session, isA<SessionCompleted>());
    },
  );

  group('SYNC-R1-06: phones set up within the same minute', () {
    test(
      'two phones whose UUIDv7 device ids share the 8-char prefix see each '
      'other in discovery',
      () async {
        // Real device ids minted ~1 s apart (two friends installing the app
        // together): UUIDv7 starts with the millisecond clock, so the first 8
        // hex chars (the advertised "device id prefix") are identical for
        // ids minted within the same 65.5 s.
        const gen = UuidV7Generator();
        var idA = gen.newId();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        var idB = gen.newId();
        if (idA.substring(0, 8) != idB.substring(0, 8)) {
          // Crossed a 65.5 s boundary between the two calls: once more.
          idA = gen.newId();
          idB = gen.newId();
        }
        expect(idA.substring(0, 8), idB.substring(0, 8));
        expect(idA, isNot(idB));
        final alex = await QaPhone.create(
          hub,
          'a',
          "Alex's Pixel",
          deviceId: idA,
        );
        final priya = await QaPhone.create(
          hub,
          'b',
          "Priya's Pixel",
          deviceId: idB,
        );
        phones.addAll([alex, priya]);
        expect(alex.deviceId, idA);
        final seed = await alex.seedGroup(expenses: 1);
        await priya.join(alex, seed.g);
        await priya.engine.startHosting();

        final peer = await alex.find(priya);
        expect(peer.sharedGroupIds, [seed.g]);
        expect((await alex.engine.syncWith(peer)).sentOps, 4);
      },
      skip:
          'QA SYNC-R1-06: discovery treats a phone whose device id shares '
          'the UUIDv7 time prefix as "self" and hides it',
    );
  });

  group('SYNC-R1-07: a phone in many groups', () {
    // A realistic user: 3 trips/homes + 17 friends (each 1:1 friend balance
    // is its own group). The scanner shares exactly one of them.
    final keys = {for (var i = 0; i < 20; i++) groupIdOf(i + 1): groupKeyOf(i)};
    final shared = groupIdOf(7);
    final scannerKeys = {shared: keys[shared]!};
    final start = DateTime.utc(2026, 11, 9, 12);
    const info = (id: 'aaaaaaaa-0000-7000-8000-000000000001', name: 'Alex');

    Future<List<String>> advertised(DateTime t) =>
        DiscoveryTokens.advertised(keys, t);

    final transports = <String, Set<String> Function(AdvertiseInfo)>{
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

    for (final MapEntry(key: name, value: decode) in transports.entries) {
      test(
        'over $name, the shared group is recognised in every token window',
        () async {
          var missed = 0;
          for (var w = 0; w < 12; w++) {
            final t = start.add(Duration(minutes: 10 * w));
            final advert = AdvertiseInfo(
              deviceId: info.id,
              deviceName: info.name,
              groupTokens: await advertised(t),
            );
            final seen = decode(advert);
            final index = await DiscoveryTokens.index(scannerKeys, t);
            if (!seen.any(index.containsKey)) missed++;
          }
          expect(
            missed,
            0,
            reason:
                'shared group hidden in $missed of 12 windows over '
                '$name: the peer shows "Pair" and tap-to-sync is refused',
          );
        },
        skip:
            'QA SYNC-R1-07: with more groups than the advert holds '
            '(Nearby 4, BLE/LAN 16), a shared group is often not advertised',
      );
    }
  });

  test(
    'SYNC-R1-08: device-to-device transfer cannot clone the device id '
    '(dataExtractionRules exclude the op log)',
    () {
      // targetSdk 36: allowBackup=false stops cloud backup, but not Android
      // 12+ device-to-device migration. A migrated op log carries the same
      // device id; if the old phone keeps writing, both phones mint the same
      // (deviceId, counter) pairs and every other phone silently drops one
      // of them as a fork (SPEC 7.4), so the group never converges.
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      final rules = RegExp(r'android:dataExtractionRules="@xml/(\w+)"')
          .firstMatch(manifest);
      expect(
        rules,
        isNotNull,
        reason: 'no android:dataExtractionRules on <application>',
      );
      final xml = File('android/app/src/main/res/xml/${rules!.group(1)}.xml')
          .readAsStringSync();
      expect(xml, contains('<device-transfer>'));
      expect(xml, contains('<exclude'));
    },
    skip:
        'QA SYNC-R1-08: no dataExtractionRules, so Android 12+ '
        'device-to-device transfer copies the op log and device id',
  );
}
