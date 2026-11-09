// LanTransport over real sockets on 127.0.0.1 (SPEC 11.3): full sync
// sessions between two DefaultSyncEngines, each over a real Ledger
// (MemoryOpStore), reached by connect link, by mDNS discovery and by the
// hotspot gateway probe. mDNS itself is faked (no platform channels here).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/lan/gateway_probe.dart';
import 'package:settle_up/sync/transport/lan/lan_network.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';
import 'package:settle_up/sync/transport/lan/tcp_framing.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../support/harness.dart';
import '../support/phone.dart';
import 'support.dart';

const Duration _fast = Duration(milliseconds: 150);

LanTransport lanTransport({
  required FakeMdns mdns,
  FakeLanNetwork? network,
  int port = 0,
  bool allowLoopbackGateway = false,
  InternetAddress? bindAddress,
  bool loopbackOnly = true,
}) =>
    LanTransport(
      port: port,
      mdns: mdns,
      network: network ?? FakeLanNetwork(),
      bindAddress:
          bindAddress ?? (loopbackOnly ? InternetAddress.loopbackIPv4 : null),
      rediscoverInterval: _fast,
      probeInterval: _fast,
      firstFrameTimeout: const Duration(seconds: 2),
      allowLoopbackGateway: allowLoopbackGateway,
    );

/// A phone: real Ledger, real engine, real LanTransport.
final class LanPhone {
  LanPhone._(this.phone, this.lan, this.mdns, this.network, this.engine);

  static Future<LanPhone> create(
    String letter,
    String name,
    FakeMdnsHub hub, {
    FakeLanNetwork? network,
    int port = 0,
    bool allowLoopbackGateway = false,
  }) async {
    final phone = await TestPhone.create(letter, deviceName: name);
    final mdns = FakeMdns(hub);
    final net = network ?? FakeLanNetwork();
    final lan = lanTransport(
      mdns: mdns,
      network: net,
      port: port,
      allowLoopbackGateway: allowLoopbackGateway,
    );
    final engine = DefaultSyncEngine(
      store: phone.ledger,
      transports: [lan],
      timings: fastTimings,
    );
    return LanPhone._(phone, lan, mdns, net, engine);
  }

  final TestPhone phone;
  final LanTransport lan;
  final FakeMdns mdns;
  final FakeLanNetwork network;
  final DefaultSyncEngine engine;

  Future<NearbyPeer> find(bool Function(NearbyPeer) match) async {
    if (!engine.status.discovering) await engine.startDiscovery();
    final list = await engine
        .watchNearby()
        .firstWhere((l) => l.any(match))
        .timeout(const Duration(seconds: 5));
    return list.firstWhere(match);
  }

  Future<void> dispose() async {
    await engine.dispose();
    await phone.close();
  }
}

AdvertiseInfo info(String name, [List<String> tokens = const []]) =>
    AdvertiseInfo(
      deviceId: deviceIdOf('z'),
      advertId: 'abcd1234',
      deviceName: name,
      groupTokens: tokens,
    );

void main() {
  late FakeMdnsHub hub;
  final cleanup = <Future<void> Function()>[];

  setUp(() {
    hub = FakeMdnsHub();
  });

  tearDown(() async {
    for (final c in cleanup.reversed) {
      await c();
    }
    cleanup.clear();
  });

  Future<LanPhone> phoneOf(
    String letter,
    String name, {
    FakeMdnsHub? onHub,
    FakeLanNetwork? network,
    int port = 0,
    bool allowLoopbackGateway = false,
  }) async {
    final p = await LanPhone.create(
      letter,
      name,
      onHub ?? hub,
      network: network,
      port: port,
      allowLoopbackGateway: allowLoopbackGateway,
    );
    cleanup.add(p.dispose);
    return p;
  }

  group('full sync over real sockets', () {
    late LanPhone alex, priya;
    late Seed seed;

    setUp(() async {
      alex = await phoneOf('a', "Alex's Pixel");
      priya = await phoneOf('b', "Priya's Pixel");
      seed = await alex.phone.seedGroup(expenses: 4);
      await priya.phone.join(alex.phone, seed.g);
    });

    test('via the connect link from host mode', () async {
      priya.network.ssid = 'Goa house';
      final host = await priya.engine.startHosting();
      final port = priya.lan.boundPort!;
      expect(host.transports, {TransportKind.lan});
      expect(host.addresses, ['127.0.0.1:$port']);
      expect(host.wifiName, 'Goa house');
      expect(ConnectLink.tryParse(host.connectLink)!.hosts, ['127.0.0.1:$port']);

      final summary = await alex.engine.syncWithLink(host.connectLink);
      expect(summary.transport, TransportKind.lan);
      expect(summary.sentOps, 7);
      expect(summary.receivedOps, 0);
      expect(summary.groupIds, [seed.g]);
      expect(priya.phone.canonical, alex.phone.canonical);

      // Both sides recorded the session.
      await pumpUntil(() async =>
          (await priya.phone.records()).isNotEmpty &&
          (await alex.phone.records()).isNotEmpty);
      expect((await priya.phone.records()).single.outcome,
          SyncOutcome.completed);
      expect((await alex.phone.records()).single.outcome, SyncOutcome.completed);

      // Concurrent edits on both phones converge in one more session.
      await alex.phone.addExpenses(seed, 3);
      await priya.phone.addExpense(seed.g,
          payer: seed.b, owers: [seed.a, seed.b], description: 'Taxi');
      final second = await alex.engine.syncWithLink(host.connectLink);
      expect(second.sentOps, 3);
      expect(second.receivedOps, 1);
      expect(priya.phone.canonical, alex.phone.canonical);
      expect(priya.phone.opCount(seed.g), 11);
    });

    test('via mDNS discovery, with shared groups from the tokens', () async {
      await priya.engine.startHosting();
      final peer = await alex.find((p) => p.name == "Priya's Pixel");
      expect(peer.transports, {TransportKind.lan});
      expect(peer.sharedGroupIds, [seed.g]);
      // A per-window advert id, never a piece of the device id (SPEC 8.3).
      expect(peer.advertId, matches(RegExp(r'^[0-9a-f]{8}$')));
      expect(priya.phone.deviceId, isNot(contains(peer.advertId!)));

      final summary = await alex.engine.syncWith(peer);
      expect(summary.sentOps, 7);
      expect(priya.phone.canonical, alex.phone.canonical);
    });

    test('a thousand ops cross in 1 MiB frames', () async {
      await alex.phone.addExpenses(seed, 1000);
      final host = await priya.engine.startHosting();
      final summary = await alex.engine.syncWithLink(host.connectLink);
      expect(summary.sentOps, 1007);
      expect(priya.phone.opCount(seed.g), 1007);
      expect(priya.phone.canonical, alex.phone.canonical);
      expect(priya.phone.duplicatesIgnored, 0);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('the joiner pulls from the host too (responder sends)', () async {
      // Priya hosts with nothing; Alex hosts the data instead.
      final host = await alex.engine.startHosting();
      final summary = await priya.engine.syncWithLink(host.connectLink);
      expect(summary.receivedOps, 7);
      expect(priya.phone.canonical, alex.phone.canonical);
    });

    test('an unreachable link host reports peerUnreachable', () async {
      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = free.port;
      await free.close();
      final link = ConnectLink(
        hosts: ['127.0.0.1:$deadPort'],
        deviceId: priya.phone.deviceId,
        deviceName: 'Priya',
      ).encode();
      await expectLater(
        alex.engine.syncWithLink(link),
        throwsA(isA<SyncException>().having(
            (e) => e.failure, 'failure', SyncFailure.peerUnreachable)),
      );
    });
  });

  group('hotspot gateway probe', () {
    test('finds the hosting phone with no mDNS and syncs through it',
        () async {
      final priya = await phoneOf('b', "Priya's Pixel", onHub: FakeMdnsHub());
      final g = (await priya.phone.seedGroup(expenses: 2)).g;
      await priya.engine.startHosting();
      final hostPort = priya.lan.boundPort!;

      // Alex joined Priya's hotspot: the gateway is Priya, mDNS is dead.
      final alex = await phoneOf(
        'a',
        "Alex's Pixel",
        network: FakeLanNetwork(
          addresses: [
            LanInterfaceAddress('wlan0', InternetAddress('10.71.4.20')),
          ],
          gateway: '127.0.0.1',
        ),
        port: hostPort,
        allowLoopbackGateway: true,
      );
      await alex.phone.join(priya.phone, g);

      final peer = await alex.find((p) => p.name == kGatewayPeerName);
      expect(peer.transports, {TransportKind.lan});
      expect(peer.advertId, isNull);
      expect(peer.sharedGroupIds, isEmpty);
      // Let a few more probes hit the host.
      await Future<void>.delayed(_fast * 4);
      expect(alex.network.gatewayReads, greaterThan(2));
      // Probes never became sessions on the host.
      expect(await priya.phone.records(), isEmpty);
      expect(priya.engine.status.session, isA<SessionIdle>());

      final summary = await alex.engine.syncWith(peer);
      expect(summary.receivedOps, 5);
      expect(alex.phone.canonical, priya.phone.canonical);
      await pumpUntil(() async => (await priya.phone.records()).length == 1);
    });

    test('our own address as gateway is never probed', () async {
      final probe = GatewayProbe(
        network: FakeLanNetwork(
          addresses: [
            LanInterfaceAddress('ap0', InternetAddress('127.0.0.1')),
          ],
          gateway: '127.0.0.1',
        ),
        port: 1,
        allowLoopbackGateway: true,
        connector: (h, p, t) => fail('must not connect'),
      );
      expect(await probe.probeOnce(), isNull);
    });

    test('no gateway, loopback or 0.0.0.0 gateway: nothing to probe',
        () async {
      for (final gw in [null, '0.0.0.0', '127.0.0.1', 'not an ip']) {
        final probe = GatewayProbe(
          network: FakeLanNetwork(addresses: const [], gateway: gw),
          port: 1,
          connector: (h, p, t) => fail('must not connect to $gw'),
        );
        expect(await probe.probeOnce(), isNull, reason: '$gw');
      }
    });

    test('a gateway that does not answer is not listed', () async {
      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = free.port;
      await free.close();
      final probe = GatewayProbe(
        network: FakeLanNetwork(addresses: const [], gateway: '127.0.0.1'),
        port: deadPort,
        allowLoopbackGateway: true,
      );
      expect(await probe.probeOnce(), isNull);
    });

    test('a gateway already seen through mDNS is listed once, with its id',
        () async {
      final priya = await phoneOf('b', "Priya's Pixel");
      await priya.phone.seedGroup(expenses: 0);
      await priya.engine.startHosting();
      final scanner = lanTransport(
        mdns: FakeMdns(hub),
        network: FakeLanNetwork(
          addresses: [
            LanInterfaceAddress('wlan0', InternetAddress('10.71.4.20')),
          ],
          gateway: '127.0.0.1',
        ),
        port: priya.lan.boundPort!,
        allowLoopbackGateway: true,
      );
      cleanup.add(scanner.dispose);
      final seen = <DiscoveredPeer>[];
      final sub = scanner.discover().listen(seen.add);
      await Future<void>.delayed(_fast * 6);
      await sub.cancel();
      expect(seen, isNotEmpty);
      expect(seen.map((p) => p.name).toSet(), {"Priya's Pixel"});
      expect(seen.every((p) => p.advertId != null), isTrue);
    });
  });

  group('LanTransport', () {
    test('discover re-emits visible peers well within 15 s', () async {
      final host = lanTransport(mdns: FakeMdns(hub));
      cleanup.add(host.dispose);
      await host.startAdvertising(info('Host', ['Tk01']));
      final scanner = lanTransport(mdns: FakeMdns(hub));
      cleanup.add(scanner.dispose);

      final seen = <DiscoveredPeer>[];
      final sub = scanner.discover().listen(seen.add);
      await Future<void>.delayed(_fast * 5);
      await sub.cancel();
      expect(seen.length, greaterThanOrEqualTo(3));
      final p = seen.first;
      expect(p.address, '127.0.0.1:${host.boundPort}');
      expect(p.name, 'Host');
      expect(p.groupTokens, {'Tk01'});
      expect(p.advertId, 'abcd1234');
    });

    test('discover hides our own advert and stops browsing on cancel',
        () async {
      final mdns = FakeMdns(hub);
      final t = lanTransport(mdns: mdns);
      cleanup.add(t.dispose);
      await t.startAdvertising(info('Me'));
      final seen = <DiscoveredPeer>[];
      final sub = t.discover().listen(seen.add);
      await Future<void>.delayed(_fast * 3);
      expect(mdns.activeBrowses, 1);
      await sub.cancel();
      expect(mdns.activeBrowses, 0);
      expect(seen, isEmpty);
    });

    test('a lost service stops being re-emitted', () async {
      final hostMdns = FakeMdns(hub);
      final host = lanTransport(mdns: hostMdns);
      cleanup.add(host.dispose);
      await host.startAdvertising(info('Host'));
      final scanner = lanTransport(mdns: FakeMdns(hub));
      cleanup.add(scanner.dispose);
      final seen = <DiscoveredPeer>[];
      final sub = scanner.discover().listen(seen.add);
      await Future<void>.delayed(_fast * 2);
      expect(seen, isNotEmpty);
      await host.stopAdvertising();
      await Future<void>.delayed(_fast);
      final count = seen.length;
      await Future<void>.delayed(_fast * 3);
      expect(seen.length, count);
      await sub.cancel();
    });

    test('repeated startAdvertising updates in place', () async {
      final mdns = FakeMdns(hub);
      final host = lanTransport(mdns: mdns);
      cleanup.add(host.dispose);
      final inbound = <FrameChannel>[];
      final inSub = host.inbound.listen(inbound.add);
      cleanup.add(inSub.cancel);

      await host.startAdvertising(info('Host', ['Tk01']));
      final port = host.boundPort!;
      expect(mdns.current!.attributes['t'], 'Tk01');

      final client = lanTransport(mdns: FakeMdns(FakeMdnsHub()));
      cleanup.add(client.dispose);
      final ch = await client.connect(DiscoveredPeer(
        kind: TransportKind.lan,
        address: '127.0.0.1:$port',
        name: 'Host',
      ));
      cleanup.add(ch.close);
      await ch.send(Uint8List.fromList([1]));
      await pumpUntil(() async => inbound.length == 1);
      final serverEnd = inbound.single;
      final fromClient = StreamIterator(serverEnd.frames);
      expect(await fromClient.moveNext(), isTrue);
      expect(fromClient.current, [1]);

      // New token window: same server, same connection, new TXT.
      await host.startAdvertising(info('Host', ['Tk02']));
      expect(host.boundPort, port);
      expect(mdns.current!.attributes['t'], 'Tk02');
      expect(mdns.current!.port, port);
      await ch.send(Uint8List.fromList([2]));
      expect(await fromClient.moveNext(), isTrue);
      expect(fromClient.current, [2]);

      // Stopping drops the server and the advert but not the session.
      await host.stopAdvertising();
      expect(host.boundPort, isNull);
      expect(mdns.current, isNull);
      expect(await host.hostAddresses(), isEmpty);
      final back = ch.frames.first;
      await serverEnd.send(Uint8List.fromList([3]));
      expect(await back, [3]);
      await expectLater(
        client.connect(DiscoveredPeer(
          kind: TransportKind.lan,
          address: '127.0.0.1:$port',
          name: 'Host',
        )),
        throwsA(isA<SocketException>()),
      );
      await fromClient.cancel();
      await serverEnd.close();
    });

    test('falls back to a free port when the preferred one is busy',
        () async {
      final squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      cleanup.add(squatter.close);
      final mdns = FakeMdns(hub);
      final t = lanTransport(mdns: mdns, port: squatter.port);
      cleanup.add(t.dispose);
      await t.startAdvertising(info('Host'));
      expect(t.boundPort, isNot(squatter.port));
      expect(t.boundPort, greaterThan(0));
      // The actual port goes into mDNS and the QR addresses.
      expect(mdns.current!.port, t.boundPort);
      expect(await t.hostAddresses(), ['127.0.0.1:${t.boundPort}']);
    });

    test('connections that close or misbehave before a frame never reach '
        'inbound', () async {
      final host = lanTransport(mdns: FakeMdns(hub));
      cleanup.add(host.dispose);
      final inbound = <FrameChannel>[];
      final inSub = host.inbound.listen(inbound.add);
      cleanup.add(inSub.cancel);
      await host.startAdvertising(info('Host'));
      final port = host.boundPort!;

      // A probe: connect and close.
      (await Socket.connect(InternetAddress.loopbackIPv4, port)).destroy();
      // Half a frame, then close.
      final half = await Socket.connect(InternetAddress.loopbackIPv4, port);
      half.add([0, 0, 0, 9, 1, 2]);
      await half.flush();
      half.destroy();
      // An oversize length.
      final evil = await Socket.connect(InternetAddress.loopbackIPv4, port);
      evil.add([0xff, 0xff, 0xff, 0xff]);
      await evil.flush();
      await evil.drain<void>().timeout(const Duration(seconds: 5));
      evil.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(inbound, isEmpty);

      // A real peer: the first frame and the rest of the read arrive.
      final good = await Socket.connect(InternetAddress.loopbackIPv4, port);
      cleanup.add(() async => good.destroy());
      good.add([
        ...encodeLanFrame(Uint8List.fromList([7])),
        ...encodeLanFrame(Uint8List.fromList([8, 8])),
        0, 0, // start of a third frame
      ]);
      await good.flush();
      await pumpUntil(() async => inbound.length == 1);
      final frames = StreamIterator(inbound.single.frames);
      expect(await frames.moveNext(), isTrue);
      expect(frames.current, [7]);
      expect(await frames.moveNext(), isTrue);
      expect(frames.current, [8, 8]);
      good.add([0, 1, 9]);
      await good.flush();
      expect(await frames.moveNext(), isTrue);
      expect(frames.current, [9]);
      expect(inbound.single.kind, TransportKind.lan);
      expect(inbound.single.maxFrameBytes, kLanMaxFrameBytes);
      await frames.cancel();
      await inbound.single.close();
    });

    test('a silent connection is dropped after the first-frame timeout',
        () async {
      final host = LanTransport(
        port: 0,
        mdns: FakeMdns(hub),
        network: FakeLanNetwork(),
        bindAddress: InternetAddress.loopbackIPv4,
        firstFrameTimeout: const Duration(milliseconds: 200),
      );
      cleanup.add(host.dispose);
      await host.startAdvertising(info('Host'));
      final s = await Socket.connect(InternetAddress.loopbackIPv4, host.boundPort!);
      cleanup.add(() async => s.destroy());
      // The server hangs up on us.
      await s.drain<void>().timeout(const Duration(seconds: 5));
    });

    test('hostAddresses on an any-address bind lists every interface',
        () async {
      final t = lanTransport(
        mdns: FakeMdns(hub),
        network: FakeLanNetwork(addresses: [
          LanInterfaceAddress('ap0', InternetAddress('10.0.0.1')),
          LanInterfaceAddress('wlan0', InternetAddress('192.168.1.5')),
          LanInterfaceAddress('wlan0', InternetAddress('192.168.1.5')),
        ]),
        loopbackOnly: false,
      );
      cleanup.add(t.dispose);
      expect(await t.hostAddresses(), isEmpty);
      await t.startAdvertising(info('Host'));
      final port = t.boundPort!;
      expect(await t.hostAddresses(), ['10.0.0.1:$port', '192.168.1.5:$port']);
    });

    test('availability: ready with an interface, radioOff without', () async {
      final net = FakeLanNetwork();
      final t = lanTransport(mdns: FakeMdns(hub), network: net);
      cleanup.add(t.dispose);
      expect(await t.availability(), TransportAvailability.ready);
      net.addresses = const [];
      expect(await t.availability(), TransportAvailability.radioOff);
      expect(await t.requestPermissions(), TransportAvailability.radioOff);
    });

    test('connect rejects bad addresses and other kinds', () async {
      final t = lanTransport(mdns: FakeMdns(hub));
      cleanup.add(t.dispose);
      await expectLater(
        t.connect(const DiscoveredPeer(
            kind: TransportKind.lan, address: 'nope:', name: '')),
        throwsA(isA<SocketException>()),
      );
      await expectLater(
        t.connect(const DiscoveredPeer(
            kind: TransportKind.ble, address: '127.0.0.1:1', name: '')),
        throwsArgumentError,
      );
    });

    test('dispose closes inbound and refuses further use', () async {
      final t = lanTransport(mdns: FakeMdns(hub));
      await t.startAdvertising(info('Host'));
      final done = t.inbound.toList();
      await t.dispose();
      expect(await done, isEmpty);
      expect(t.boundPort, isNull);
      await expectLater(t.startAdvertising(info('Host')), throwsStateError);
    });
  });
}

/// Polls [condition] until it holds (5 s max).
Future<void> pumpUntil(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
