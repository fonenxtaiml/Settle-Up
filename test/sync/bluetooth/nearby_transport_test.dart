// NearbyTransport over a fake Nearby Connections radio: discovery from the
// endpoint name, re-emission while visible, in-place re-advertising,
// connection setup both ways, frame delivery and limits, failures, and a
// full sync between two DefaultSyncEngines.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/platform/permissions.dart';
import 'package:settle_up/sync/transport/nearby/nearby_endpoint_name.dart';
import 'package:settle_up/sync/transport/nearby/nearby_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'support/bt_phone.dart';
import 'support/fake_nearby.dart';
import 'support/fake_permissions.dart';

const Duration _rediscover = Duration(milliseconds: 100);

String token(int n) => 'T${n.toRadixString(36).padLeft(3, '0')}';

AdvertiseInfo info(String letter, String name, [List<String>? tokens]) =>
    AdvertiseInfo(
      deviceId: '${letter * 8}-0000-7000-8000-000000000001',
      advertId: letter * 8,
      deviceName: name,
      groupTokens: tokens ?? [token(1)],
    );

Uint8List frame(int n, [int fill = 7]) =>
    Uint8List.fromList(List.filled(n, fill));

void main() {
  late FakeNearbyAir air;
  final cleanup = <Future<void> Function()>[];

  setUp(() => air = FakeNearbyAir());

  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
  });

  NearbyTransport transport(FakeNearbyApi api, {bool isAndroid = true}) {
    final t = NearbyTransport(
      permissions: grantedPermissions(),
      api: api,
      isAndroid: isAndroid,
      rediscoverInterval: _rediscover,
    );
    cleanup.add(t.dispose);
    return t;
  }

  group('availability', () {
    test('unsupported off Android, without touching the plugin', () async {
      final api = air.phone('A');
      final t = transport(api, isAndroid: false);
      expect(await t.availability(), TransportAvailability.unsupported);
      expect(await t.requestPermissions(), TransportAvailability.unsupported);
      expect(api.calls, isEmpty);
    });

    test('on Android it follows the permission wrapper', () async {
      final platform = FakePermissionPlatform(granted: false);
      final t = NearbyTransport(
        permissions: NearbyPermissions(platform: platform),
        api: air.phone('A'),
        isAndroid: true,
      );
      cleanup.add(t.dispose);
      expect(await t.availability(), TransportAvailability.needsPermission);
      expect(await t.requestPermissions(), TransportAvailability.ready);
      expect(platform.requests, 1);
      platform.radio = RadioState.off;
      expect(await t.availability(), TransportAvailability.radioOff);
    });
  });

  group('discovery', () {
    test('parses the endpoint name into a peer', () async {
      final a = transport(air.phone('A'));
      final b = transport(air.phone('B'));
      await b.startAdvertising(info('b', "Priya's Pixel", [token(1), token(2)]));

      final peer = await a.discover().first;
      expect(peer.kind, TransportKind.nearby);
      expect(peer.address, 'B');
      expect(peer.name, "Priya's Pixel");
      expect(peer.advertId, 'bbbbbbbb');
      expect(peer.groupTokens, {token(1), token(2)});
    });

    test('re-emits a found endpoint while it stays visible', () async {
      final a = transport(air.phone('A'));
      final b = transport(air.phone('B'));
      await b.startAdvertising(info('b', 'Priya'));
      final seen = <DateTime>[];
      final sub = a.discover().listen((_) => seen.add(DateTime.now()));
      await pumpUntil(() => seen.length >= 4);
      // Nearby reported it once; the rest are re-emissions.
      expect(air.phone('A').count('startDiscovery'), 1);

      await b.stopAdvertising();
      await Future<void>.delayed(_rediscover * 2);
      final after = seen.length;
      await Future<void>.delayed(_rediscover * 3);
      expect(seen.length, after, reason: 'a lost endpoint is not re-emitted');
      await sub.cancel();
    });

    test('ignores endpoints whose name is not ours', () async {
      final a = transport(air.phone('A'));
      final rogue = air.phone('R');
      await rogue.startAdvertising('Some other app');
      final b = transport(air.phone('B'));
      await b.startAdvertising(info('b', 'Priya'));
      final peers = await a.discover().take(2).toList();
      expect(peers.map((p) => p.address).toSet(), {'B'});
    });

    test('scans only while listened to', () async {
      final api = air.phone('A');
      final a = transport(api);
      final sub = a.discover().listen((_) {});
      await pumpUntil(() => api.discovering);
      expect(a.isDiscovering, isTrue);
      await sub.cancel();
      expect(api.discovering, isFalse);
      expect(api.count('stopDiscovery'), 1);

      // A second scan starts the plugin again.
      final again = a.discover().listen((_) {});
      await pumpUntil(() => api.discovering);
      await again.cancel();
      expect(api.count('startDiscovery'), 2);
    });

    test('two listeners share one plugin scan', () async {
      final api = air.phone('A');
      final a = transport(api);
      final b = transport(air.phone('B'));
      await b.startAdvertising(info('b', 'Priya'));
      final one = a.discover().first;
      final two = a.discover().first;
      expect((await one).address, 'B');
      expect((await two).address, 'B');
      await pumpUntil(() => !api.discovering);
      expect(api.count('startDiscovery'), 1);
    });
  });

  group('advertising', () {
    test('a repeated call with the same info is a no-op', () async {
      final api = air.phone('B');
      final b = transport(api);
      await b.startAdvertising(info('b', 'Priya'));
      await b.startAdvertising(info('b', 'Priya'));
      expect(api.count('startAdvertising'), 1);
      expect(api.count('stopAdvertising'), 0);
      expect(b.advertisedName, startsWith('2|bbbbbbbb||Priya|'));
    });

    test('new tokens update the name in place; open channels stay',
        () async {
      final apiB = air.phone('B');
      final a = transport(air.phone('A'));
      final b = transport(apiB);
      final inbound = <FrameChannel>[];
      b.inbound.listen(inbound.add);
      await b.startAdvertising(info('b', 'Priya', [token(1)]));

      final ca = await a.connect(await a.discover().first);
      await pumpUntil(() => inbound.length == 1);

      await b.startAdvertising(info('b', 'Priya', [token(2)]));
      expect(apiB.count('stopAdvertising'), 1);
      expect(apiB.count('startAdvertising'), 2);
      expect(NearbyEndpointName.tryParse(apiB.advertisedName!)!.groupTokens,
          [token(2)]);

      // The channel opened before the update still works both ways.
      final got = inbound.single.frames.first;
      await ca.send(frame(10));
      expect(await got, frame(10));

      // And a scanner sees the new tokens.
      final scanner = transport(air.phone('C'));
      final peer = await scanner.discover().first;
      expect(peer.groupTokens, {token(2)});
    });

    test('a failed start leaves the transport not advertising', () async {
      final api = air.phone('B');
      await api.startAdvertising('held by someone else');
      final b = transport(api);
      await expectLater(
          b.startAdvertising(info('b', 'Priya')), throwsStateError);
      expect(b.isAdvertising, isFalse);
    });

    test('stop is idempotent and inbound requests are refused after it',
        () async {
      final apiB = air.phone('B');
      final a = transport(air.phone('A'));
      final b = transport(apiB);
      await b.startAdvertising(info('b', 'Priya'));
      final peer = await a.discover().first;
      await b.stopAdvertising();
      await b.stopAdvertising();
      expect(apiB.count('stopAdvertising'), 1);

      // The fake refuses requests to non-advertisers; make B advertise
      // with the raw plugin so the request reaches the transport.
      await apiB.startAdvertising('raw advert');
      await expectLater(
        a.connect(peer, timeout: const Duration(seconds: 1)),
        throwsA(isA<SocketException>()),
      );
      expect(apiB.count('rejectConnection'), 1);
    });
  });

  group('channels', () {
    late NearbyTransport a, b;
    late FakeNearbyApi apiA, apiB;
    late DiscoveredPeer peer;
    late List<FrameChannel> inbound;

    setUp(() async {
      apiA = air.phone('A');
      apiB = air.phone('B');
      a = transport(apiA);
      b = transport(apiB);
      inbound = [];
      b.inbound.listen(inbound.add);
      await b.startAdvertising(info('b', 'Priya'));
      peer = await a.discover().first;
    });

    test('connect accepts on both sides and carries frames in order',
        () async {
      final ca = await a.connect(peer);
      await pumpUntil(() => inbound.length == 1);
      final cb = inbound.single;
      expect(ca.kind, TransportKind.nearby);
      expect(ca.peerAddress, 'B');
      expect(cb.peerAddress, 'A');
      expect(ca.maxFrameBytes, kNearbyMaxFrameBytes);
      expect(apiA.count('acceptConnection'), 1);
      expect(apiB.count('acceptConnection'), 1);

      final atB = <Uint8List>[];
      final atA = <Uint8List>[];
      cb.frames.listen(atB.add);
      ca.frames.listen(atA.add);
      for (var i = 0; i < 20; i++) {
        unawaited(ca.send(frame(100 + i, i)));
      }
      await cb.send(frame(kNearbyMaxFrameBytes, 3));
      await pumpUntil(() => atB.length == 20 && atA.length == 1);
      for (var i = 0; i < 20; i++) {
        expect(atB[i], frame(100 + i, i));
      }
      expect(atA.single.length, kNearbyMaxFrameBytes);
      // One frame is exactly one payload.
      expect(apiA.sent['B'], hasLength(20));
    });

    test('send refuses frames over 32 KiB and anything after close',
        () async {
      final ca = await a.connect(peer);
      await expectLater(
          ca.send(frame(kNearbyMaxFrameBytes + 1)), throwsArgumentError);
      await ca.close();
      await expectLater(ca.send(frame(1)), throwsStateError);
    });

    test('a local close ends the peer channel', () async {
      final ca = await a.connect(peer);
      await pumpUntil(() => inbound.length == 1);
      final done = inbound.single.frames.toList();
      await ca.close();
      expect(await done, isEmpty);
      expect(a.openChannels, 0);
      await pumpUntil(() => b.openChannels == 0);
    });

    test('a dropped link ends both channels', () async {
      final ca = await a.connect(peer);
      await pumpUntil(() => inbound.length == 1);
      final doneA = ca.frames.toList();
      final doneB = inbound.single.frames.toList();
      apiA.dropLink('B');
      expect(await doneA, isEmpty);
      expect(await doneB, isEmpty);
      await expectLater(ca.send(frame(1)), throwsStateError);
    });

    test('a failed payload errors the channel', () async {
      final ca = await a.connect(peer);
      await pumpUntil(() => inbound.length == 1);
      apiA.failPayloadNumber = 2;
      final atB = inbound.single.frames.toList();
      await ca.send(frame(5));
      await ca.send(frame(6));
      await expectLater(atB, throwsA(isA<SocketException>()));
    });

    test('an oversized incoming payload errors the channel', () async {
      final ca = await a.connect(peer);
      final got = ca.frames.toList();
      apiA.receiveFrom('B', frame(kNearbyMaxFrameBytes + 1));
      await expectLater(got, throwsA(isA<SocketException>()));
    });

    test('a peer that never answers times out', () async {
      apiB.ignoreConnectionRequests = true;
      await expectLater(
        a.connect(peer, timeout: const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
      expect(a.openChannels, 0);
      // The endpoint can be tried again.
      apiB.ignoreConnectionRequests = false;
      expect((await a.connect(peer)).peerAddress, 'B');
    });

    test('a retried inbound request replaces one that never completed',
        () async {
      // A raw phone (no transport) asks twice and only accepts the second.
      final raw = air.phone('R');
      await raw.requestConnection('1|rrrrrrrr|Raw|', 'B');
      await pumpUntil(() => apiB.count('acceptConnection') == 1);
      await raw.requestConnection('1|rrrrrrrr|Raw|', 'B');
      await pumpUntil(() => apiB.count('acceptConnection') == 2);
      expect(apiB.count('rejectConnection'), 0);
      await raw.acceptConnection('B');
      await pumpUntil(() => inbound.isNotEmpty);
      expect(inbound.single.peerAddress, 'R');
    });

    test('an unreachable endpoint fails with a SocketException', () async {
      await b.stopAdvertising();
      await expectLater(a.connect(peer), throwsA(isA<SocketException>()));
    });

    test('a second connect to a connected endpoint is refused', () async {
      await a.connect(peer);
      await expectLater(a.connect(peer), throwsA(isA<SocketException>()));
    });

    test('connect checks the peer kind', () async {
      await expectLater(
        a.connect(const DiscoveredPeer(
          kind: TransportKind.ble,
          address: 'B',
          name: '',
        )),
        throwsArgumentError,
      );
    });

    test('dispose closes channels and stops the plugin', () async {
      final ca = await a.connect(peer);
      final done = ca.frames.toList();
      await a.dispose();
      expect(await done, isEmpty);
      expect(apiA.count('stopAllEndpoints'), 1);
      expect(apiA.discovering, isFalse);
      await expectLater(a.connect(peer), throwsStateError);
    });
  });

  group('end to end', () {
    test('two engines sync a group over Nearby', () async {
      final alex = await BtPhone.create(
          'a', "Alex's Pixel", transport(air.phone('A')));
      final priya = await BtPhone.create(
          'b', "Priya's Pixel", transport(air.phone('B')));
      cleanup.add(alex.dispose);
      cleanup.add(priya.dispose);
      final seed = await alex.phone.seedGroup(expenses: 4);
      await priya.phone.join(alex.phone, seed.g);
      await alex.phone.addExpenses(seed, 300);

      final host = await priya.engine.startHosting();
      expect(host.transports, {TransportKind.nearby});
      final peer = await alex.find((p) => p.name == "Priya's Pixel");
      expect(peer.transports, {TransportKind.nearby});
      expect(peer.sharedGroupIds, [seed.g]);

      final summary = await alex.engine.syncWith(peer);
      expect(summary.transport, TransportKind.nearby);
      expect(summary.sentOps, 307);
      expect(priya.phone.canonical, alex.phone.canonical);

      // Every payload stayed within one Nearby BYTES payload.
      final sizes = air.phone('A').sent['B']!.map((f) => f.length);
      expect(sizes.every((s) => s <= kNearbyMaxFrameBytes), isTrue);
      expect(sizes.length, greaterThan(2), reason: 'batched into frames');
    });
  });
}
