// BleTransport over a fake GATT radio: INFO probing and its 60 s cache,
// re-emission while advertising, in-place re-advertising, MTU negotiation
// and chunk sizes, notify flow control and retries, broken chunk streams,
// one link at a time, and full syncs between two DefaultSyncEngines.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/platform/permissions.dart';
import 'package:settle_up/sync/transport/ble/ble_chunker.dart';
import 'package:settle_up/sync/transport/ble/ble_transport.dart';
import 'package:settle_up/sync/transport/ble/ble_uuids.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'support/bt_phone.dart';
import 'support/fake_ble.dart';
import 'support/fake_permissions.dart';

const Duration _tick = Duration(milliseconds: 100);

String token(int n) => n.toRadixString(16).padLeft(16, '0');

AdvertiseInfo info(String letter, String name, [List<String>? tokens]) =>
    AdvertiseInfo(
      deviceId: '${letter * 8}-0000-7000-8000-000000000001',
      deviceName: name,
      groupTokens: tokens ?? [token(1)],
    );

Uint8List frame(int n, [int seed = 0]) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + seed) & 0xff));

void main() {
  late FakeBleAir air;
  final cleanup = <Future<void> Function()>[];

  setUp(() => air = FakeBleAir());

  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
  });

  BleTransport transport(
    String id, {
    Duration infoCacheFor = const Duration(seconds: 60),
    Duration probeRetryAfter = const Duration(seconds: 10),
    NearbyPermissions? permissions,
  }) {
    final t = BleTransport(
      permissions: permissions ?? grantedPermissions(),
      central: air.central(id),
      peripheral: air.peripheral(id),
      rediscoverInterval: _tick,
      visibleFor: const Duration(milliseconds: 300),
      infoCacheFor: infoCacheFor,
      probeTimeout: const Duration(milliseconds: 500),
      probeRetryAfter: probeRetryAfter,
      notifyRetryDelay: const Duration(milliseconds: 1),
    );
    cleanup.add(t.dispose);
    return t;
  }

  test('GATT layout is the frozen one', () {
    expect(kBleServiceUuid, '82101e6c-f454-4ceb-86a8-5375a3b1a414');
    expect(kBleInfoUuid, 'cdc76358-cfae-4208-855b-5d0c5b179f6a');
    expect(kBleRxUuid, 'fb7ee064-81d8-47d5-87dc-a89a5e02dbe7');
    expect(kBleTxUuid, '33453450-cada-4c25-afb0-ba2115611155');
    expect(kBleRequestedMtu, 517);
  });

  group('availability', () {
    test('follows the permission wrapper', () async {
      final platform = FakePermissionPlatform(granted: false);
      final t = transport('A',
          permissions: NearbyPermissions(platform: platform));
      expect(await t.availability(), TransportAvailability.needsPermission);
      expect(await t.requestPermissions(), TransportAvailability.ready);
      platform.radio = RadioState.off;
      expect(await t.availability(), TransportAvailability.radioOff);
    });

    test('iOS is supported (BLE is its only Bluetooth path)', () async {
      final t = transport('A',
          permissions: grantedPermissions(os: PermissionOs.ios));
      expect(await t.availability(), TransportAvailability.ready);
    });
  });

  group('discovery', () {
    test('probes a new peripheral once: connect, read INFO, disconnect',
        () async {
      final a = transport('A');
      final b = transport('B');
      final inbound = <FrameChannel>[];
      b.inbound.listen(inbound.add);
      await b.startAdvertising(info('b', 'Sam iPhone', [token(1), token(2)]));

      final peer = await a.discover().first;
      expect(peer.kind, TransportKind.ble);
      expect(peer.address, 'B');
      expect(peer.name, 'Sam iPhone');
      expect(peer.deviceIdPrefix, 'bbbbbbbb');
      expect(peer.groupTokens, {token(1), token(2)});

      final central = air.central('A');
      await pumpUntil(() => central.connectedTo.isEmpty);
      expect(central.count('readInfo'), 1);
      expect(central.count('disconnect'), greaterThanOrEqualTo(1));
      // Reading INFO is not a session.
      expect(inbound, isEmpty);
    });

    test('re-emits the cached peer while it advertises, without re-reading',
        () async {
      final a = transport('A');
      final b = transport('B');
      await b.startAdvertising(info('b', 'Priya'));
      final seen = <DiscoveredPeer>[];
      final sub = a.discover().listen(seen.add);
      await pumpUntil(() => seen.length >= 5);
      expect(air.central('A').count('readInfo'), 1);

      // Gone quiet: no more emissions once it is no longer visible.
      await b.stopAdvertising();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final after = seen.length;
      await Future<void>.delayed(_tick * 3);
      expect(seen.length, after);
      await sub.cancel();
    });

    test('after the cache expires it re-reads and sees new tokens', () async {
      final a = transport('A', infoCacheFor: const Duration(milliseconds: 250));
      final b = transport('B');
      await b.startAdvertising(info('b', 'Priya', [token(1)]));
      final seen = <DiscoveredPeer>[];
      final sub = a.discover().listen(seen.add);
      await pumpUntil(() => seen.isNotEmpty);
      expect(seen.first.groupTokens, {token(1)});

      // The token window changes: INFO is swapped in place.
      await b.startAdvertising(info('b', 'Priya', [token(2)]));
      expect(air.peripheral('B').count('startAdvertising'), 1);
      await pumpUntil(() => seen.last.groupTokens.contains(token(2)));
      expect(air.central('A').count('readInfo'), greaterThanOrEqualTo(2));
      await sub.cancel();
    });

    test('a peripheral with unreadable INFO is skipped and retried later',
        () async {
      final a = transport('A',
          probeRetryAfter: const Duration(milliseconds: 300));
      final b = transport('B');
      await b.startAdvertising(info('b', 'Priya'));
      final central = air.central('A')..garbageInfo.add('B');
      final seen = <DiscoveredPeer>[];
      final sub = a.discover().listen(seen.add);
      await pumpUntil(() => central.count('readInfo') >= 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seen, isEmpty);
      expect(central.count('readInfo'), 1, reason: 'no retry storm');

      central.garbageInfo.clear();
      await pumpUntil(() => seen.isNotEmpty);
      expect(seen.first.name, 'Priya');
      await sub.cancel();
    });

    test('scans only while listened to', () async {
      final a = transport('A');
      final central = air.central('A');
      final sub = a.discover().listen((_) {});
      await pumpUntil(() => central.scanning);
      expect(a.isScanning, isTrue);
      await sub.cancel();
      expect(central.scanning, isFalse);
      expect(central.count('stopScan'), 1);
    });

    test('a scan stopped before its probe ran probes on the next scan',
        () async {
      final a = transport('A',
          probeRetryAfter: const Duration(milliseconds: 300));
      final b = transport('B');
      final c = transport('C');
      await b.startAdvertising(info('b', 'Priya'));
      await c.startAdvertising(info('c', 'Sam'));
      final central = air.central('A')..connectHangs = true;
      // The first probe hangs, so the second phone stays queued.
      final sub = a.discover().listen((_) {});
      await pumpUntil(() => central.count('connect') == 1);
      await Future<void>.delayed(_tick * 2);
      await sub.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      central.connectHangs = false;

      final names = <String>{};
      final again = a.discover().listen((p) => names.add(p.name));
      await pumpUntil(() => names.containsAll(['Priya', 'Sam']));
      await again.cancel();
    });

    test('a new listener gets visible cached peers at once', () async {
      final a = transport('A');
      final b = transport('B');
      await b.startAdvertising(info('b', 'Priya'));
      final first = a.discover().listen((_) {});
      await pumpUntil(() => air.central('A').count('readInfo') == 1);
      await Future<void>.delayed(_tick);
      final second = await a.discover().first.timeout(_tick ~/ 2);
      expect(second.address, 'B');
      await first.cancel();
    });
  });

  group('advertising', () {
    test('a repeated call only swaps INFO', () async {
      final b = transport('B');
      final p = air.peripheral('B');
      await b.startAdvertising(info('b', 'Priya', [token(1)]));
      await b.startAdvertising(info('b', 'Priya', [token(2)]));
      expect(p.count('startAdvertising'), 1);
      expect(p.count('stopAdvertising'), 0);
      expect(b.isAdvertising, isTrue);

      final a = transport('A');
      expect((await a.discover().first).groupTokens, {token(2)});
    });

    test('a central that subscribes after stop is turned away', () async {
      final a = transport('A');
      final b = transport('B');
      await b.startAdvertising(info('b', 'Priya'));
      final peer = await a.discover().first;
      await b.stopAdvertising();
      air.peripheral('B').connectable = true;
      final inbound = <FrameChannel>[];
      b.inbound.listen(inbound.add);
      final ca = await a.connect(peer);
      await expectLater(ca.frames.toList(), completion(isEmpty));
      expect(inbound, isEmpty);
    });

    test('a failed start leaves it not advertising', () async {
      final p = air.peripheral('B')..advertising = true;
      final b = transport('B');
      await expectLater(b.startAdvertising(info('b', 'Priya')),
          throwsStateError);
      expect(b.isAdvertising, isFalse);
      p.advertising = false;
    });
  });

  group('channels', () {
    late BleTransport a, b;
    late FakeBleCentral centralA;
    late FakeBlePeripheral peripheralB;
    late DiscoveredPeer peer;
    late List<FrameChannel> inbound;

    setUp(() async {
      a = transport('A');
      b = transport('B');
      centralA = air.central('A');
      peripheralB = air.peripheral('B');
      inbound = [];
      b.inbound.listen(inbound.add);
      await b.startAdvertising(info('b', 'Priya'));
      final scan = a.discover().listen((_) {});
      await pumpUntil(() => centralA.count('readInfo') == 1);
      peer = const DiscoveredPeer(kind: TransportKind.ble, address: 'B', name: '');
      await pumpUntil(() => centralA.connectedTo.isEmpty);
      await scan.cancel();
    });

    Future<(FrameChannel, FrameChannel)> open() async {
      final ca = await a.connect(peer);
      await pumpUntil(() => inbound.isNotEmpty);
      return (ca, inbound.last);
    }

    test('connect asks for MTU 517, subscribes and opens both ends',
        () async {
      final (ca, cb) = await open();
      expect(centralA.calls, containsAllInOrder([
        'connect',
        'requestMtu:517',
        'discoverService',
        'setTxNotify:true',
      ]));
      expect(ca.kind, TransportKind.ble);
      expect(ca.peerAddress, 'B');
      expect(cb.peerAddress, 'A');
      expect(ca.maxFrameBytes, kBleMaxFrameBytes);
      expect(cb.maxFrameBytes, kBleMaxFrameBytes);
      expect(a.openChannels, 1);
      expect(b.openChannels, 1);
    });

    for (final (label, mtu, canRequest) in [
      ('MTU 23 (no negotiation, like iOS)', 23, false),
      ('MTU 185', 185, true),
      ('MTU 517', 517, true),
    ]) {
      test('16 KiB frames both ways at $label', () async {
        centralA
          ..canRequestMtu = canRequest
          ..maxMtu = mtu;
        final (ca, cb) = await open();
        final atB = <Uint8List>[];
        final atA = <Uint8List>[];
        cb.frames.listen(atB.add);
        ca.frames.listen(atA.add);
        final frames = [
          frame(kBleMaxFrameBytes, 1),
          frame(1, 2),
          frame(0, 3),
          frame(700, 4),
        ];
        for (final f in frames) {
          unawaited(ca.send(f));
          unawaited(cb.send(f));
        }
        await pumpUntil(() => atA.length == 4 && atB.length == 4);
        expect(atB, frames);
        expect(atA, frames);

        final att = bleAttPayloadForMtu(mtu);
        expect(centralA.writeSizes.reduce((x, y) => x > y ? x : y), att);
        expect(peripheralB.notifySizes.reduce((x, y) => x > y ? x : y), att);
        // A 16 KiB frame took the expected number of writes.
        expect(centralA.writeSizes.length,
            frames.fold<int>(0, (n, f) => n +
                BleChunker.chunkCount(f.length, attPayload: att)));
      });
    }

    test('a busy notify queue is retried until it drains', () async {
      final (ca, cb) = await open();
      peripheralB.failNotifies = 30;
      final got = ca.frames.first;
      await cb.send(frame(100));
      expect(await got, frame(100));
      expect(peripheralB.notifyAttempts, greaterThan(30));
    });

    test('notify gives up after 50 attempts and fails the channel',
        () async {
      final (_, cb) = await open();
      peripheralB.failNotifies = 1000;
      final ended = cb.frames.toList();
      await expectLater(cb.send(frame(10)), throwsA(isA<SocketException>()));
      expect(peripheralB.notifyAttempts, 50);
      await expectLater(ended, throwsA(isA<SocketException>()));
      await expectLater(cb.send(frame(1)), throwsStateError);
    });

    test('a lost chunk breaks the stream on both sides', () async {
      final (ca, cb) = await open();
      peripheralB.dropRxChunkNumber = 3;
      final atB = cb.frames.toList();
      final atA = ca.frames.toList();
      // Chunk 3 vanishes; chunk 4 shows the gap and is refused.
      await expectLater(
          ca.send(frame(3000)), throwsA(isA<SocketException>()));
      await expectLater(atB, throwsA(isA<SocketException>()));
      await expectLater(atA, throwsA(isA<SocketException>()));
      await pumpUntil(() => centralA.connectedTo.isEmpty);
    });

    test('a hostile chunk with a bad sequence number closes the channel',
        () async {
      final (_, cb) = await open();
      final ended = cb.frames.toList();
      expect(peripheralB.writeFrom('A', Uint8List.fromList([3, 99, 1])),
          isFalse);
      await expectLater(ended, throwsA(isA<SocketException>()));
    });

    test('closing one end ends the other', () async {
      final (ca, cb) = await open();
      final atB = cb.frames.toList();
      await ca.close();
      expect(await atB, isEmpty);
      await pumpUntil(() => a.openChannels == 0 && b.openChannels == 0);
      await expectLater(ca.send(frame(1)), throwsStateError);
    });

    test('a dropped link ends both channels', () async {
      final (ca, cb) = await open();
      final atA = ca.frames.toList();
      final atB = cb.frames.toList();
      centralA.dropLink('B');
      expect(await atA, isEmpty);
      expect(await atB, isEmpty);
    });

    test('send checks the 16 KiB cap', () async {
      final (ca, _) = await open();
      await expectLater(
          ca.send(frame(kBleMaxFrameBytes + 1)), throwsArgumentError);
    });

    test('a late disconnect report from the INFO probe spares the session',
        () async {
      // Probe, then tap Sync while the probe's disconnect report is still
      // on its way from the platform: it lands during the new connect.
      centralA
        ..disconnectReportDelay = const Duration(milliseconds: 100)
        ..connectDelay = const Duration(milliseconds: 250);
      final c = transport('C');
      await c.startAdvertising(info('c', 'Third phone'));
      final scan = a.discover().listen((_) {});
      await pumpUntil(() => centralA.count('disconnect') >= 2);
      await scan.cancel();
      final inboundC = c.inbound.first;
      final ca = await a.connect(const DiscoveredPeer(
          kind: TransportKind.ble, address: 'C', name: ''));
      final cc = await inboundC;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final got = cc.frames.first;
      await ca.send(frame(50));
      expect(await got, frame(50));
    });

    test('one link at a time: a second connect is refused', () async {
      await open();
      await expectLater(a.connect(peer), throwsA(isA<SocketException>()));
    });

    test('probes wait while a channel is open, then resume', () async {
      final (ca, _) = await open();
      final c = transport('C');
      await c.startAdvertising(info('c', 'Third phone'));
      final seen = <DiscoveredPeer>[];
      final sub = a.discover().listen(seen.add);
      await Future<void>.delayed(_tick * 3);
      expect(seen.where((p) => p.address == 'C'), isEmpty);
      expect(centralA.connectedTo, ['B']);

      await ca.close();
      await pumpUntil(() => seen.any((p) => p.address == 'C'));
      await sub.cancel();
    });

    test('a peripheral that never answers times out and is let go',
        () async {
      centralA.connectHangs = true;
      await expectLater(
        a.connect(peer, timeout: const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      expect(a.openChannels, 0);
      centralA.connectHangs = false;
      // The link is free again.
      final ca = await a.connect(peer);
      expect(ca.peerAddress, 'B');
    });

    test('connect checks the peer kind', () async {
      await expectLater(
        a.connect(const DiscoveredPeer(
            kind: TransportKind.nearby, address: 'B', name: '')),
        throwsArgumentError,
      );
    });

    test('dispose closes channels and stops the radio', () async {
      final (ca, _) = await open();
      final ended = ca.frames.toList();
      await a.dispose();
      expect(await ended, isEmpty);
      expect(centralA.connectedTo, isEmpty);
      await expectLater(a.connect(peer), throwsStateError);
    });
  });

  group('INFO value', () {
    test('is the spec JSON and fits one attribute', () async {
      final b = transport('B');
      await b.startAdvertising(info('b', '😀' * 50,
          [for (var i = 0; i < 20; i++) token(i)]));
      final a = transport('A');
      final peer = await a.discover().first;
      expect(peer.groupTokens.length, lessThanOrEqualTo(16));
      expect(peer.name.runes.length, 40);
      // Read it the way a scanner does.
      final central = air.central('A');
      await central.connect('B');
      final raw = await central.readInfo('B');
      expect(raw.length, lessThanOrEqualTo(512));
      final json = jsonDecode(utf8.decode(raw)) as Map<String, Object?>;
      expect(json.keys, containsAll(['v', 'd', 'n', 't']));
      expect(json['v'], 1);
    });
  });

  group('end to end', () {
    Future<(BtPhone, BtPhone)> pair() async {
      final alex = await BtPhone.create('a', "Alex's Pixel", transport('A'));
      final sam = await BtPhone.create('b', 'Sam iPhone', transport('B'));
      cleanup.add(alex.dispose);
      cleanup.add(sam.dispose);
      return (alex, sam);
    }

    test('two engines sync a group over BLE (Android central, MTU 517)',
        () async {
      final (alex, sam) = await pair();
      final seed = await alex.phone.seedGroup(expenses: 4);
      await sam.phone.join(alex.phone, seed.g);
      await alex.phone.addExpenses(seed, 400);

      final host = await sam.engine.startHosting();
      expect(host.transports, {TransportKind.ble});
      final peer = await alex.find((p) => p.name == 'Sam iPhone');
      expect(peer.transports, {TransportKind.ble});
      expect(peer.sharedGroupIds, [seed.g]);

      final summary = await alex.engine.syncWith(peer);
      expect(summary.transport, TransportKind.ble);
      expect(summary.sentOps, 407);
      expect(sam.phone.canonical, alex.phone.canonical);
      // Frames were BLE sized.
      expect(air.central('A').writeSizes.every((s) => s <= 512), isTrue);

      // Edits on both phones meet in a second session.
      await sam.phone.addExpenses(seed, 50, base: 9000);
      await alex.phone.addExpenses(seed, 5, base: 500);
      final again = await alex.engine.syncWith(
          await alex.find((p) => p.name == 'Sam iPhone'));
      expect(again.sentOps, 5);
      expect(again.receivedOps, 50);
      expect(sam.phone.canonical, alex.phone.canonical);
    });

    test('two engines sync over BLE at MTU 23 (iPhone central)', () async {
      final (alex, sam) = await pair();
      air.central('A').canRequestMtu = false;
      final seed = await alex.phone.seedGroup(expenses: 30);
      await sam.phone.join(alex.phone, seed.g);

      await sam.engine.startHosting();
      final peer = await alex.find((p) => p.name == 'Sam iPhone');
      final summary = await alex.engine.syncWith(peer);
      expect(summary.sentOps, 33);
      expect(sam.phone.canonical, alex.phone.canonical);
      expect(air.central('A').writeSizes.every((s) => s <= 20), isTrue);
      expect(air.central('A').count('requestMtu:517'), 1);
    });
  });
}
