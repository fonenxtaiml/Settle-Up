// Connect links and invite hosts may only make the phone dial addresses on
// a local network (SPEC 8.6, SECURITY-R1-14).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/lan/local_address.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../support/phone.dart';

void main() {
  group('isLocalNetworkHostPort', () {
    test('private, link-local and loopback IP addresses are local', () {
      for (final h in [
        '10.0.0.2:52741',
        '172.16.0.1:1',
        '172.31.255.254:52741',
        '192.168.43.1:52741',
        '169.254.10.20:52741',
        '127.0.0.1:52741',
        '[fe80::1]:52741',
        '[fe80::1%wlan0]:52741',
        '[fd12:3456::1]:52741',
        '[::1]:52741',
        '[::ffff:192.168.1.5]:52741',
        '192.168.1.5', // bare host, default port
      ]) {
        expect(isLocalNetworkHostPort(h), isTrue, reason: h);
      }
    });

    test('public addresses, names and junk are not', () {
      for (final h in [
        '203.0.113.7:52741',
        '8.8.8.8:53',
        '172.32.0.1:52741',
        '172.15.255.255:52741',
        '100.64.0.1:52741', // carrier NAT, not the shared hotspot
        '[2001:db8::5]:52741',
        '[::ffff:8.8.8.8]:52741',
        'evil.example.com:443',
        'localhost:52741',
        'priya-phone:52741',
        '',
        '[fe80::1',
        '10.0.0.2:0',
        '10.0.0.2:99999',
      ]) {
        expect(isLocalNetworkHostPort(h), isFalse, reason: h);
      }
    });
  });

  group('the engine', () {
    late TestPhone alex;
    late List<String> dialed;
    late DefaultSyncEngine engine;

    setUp(() async {
      alex = await TestPhone.create('a', deviceName: 'Alex');
      dialed = [];
      engine = DefaultSyncEngine(
        store: alex.ledger,
        transports: [_DialRecorder(dialed)],
        linkConnectTimeout: const Duration(milliseconds: 100),
      );
    });

    tearDown(() async {
      await engine.dispose();
      await alex.close();
    });

    test('dials only the local hosts of a connect link', () async {
      const link = ConnectLink(
        hosts: ['203.0.113.7:52741', '192.168.1.5:52741', 'evil.example.com:1'],
        deviceId: 'ffffffff-0000-7000-8000-000000000001',
        deviceName: 'Phone X',
      );
      await expectLater(
        engine.syncWithLink(link.encode()),
        throwsA(isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.peerUnreachable,
        )),
      );
      expect(dialed, ['192.168.1.5:52741']);
    });

    test('a link with no local host is invalidCode and dials nothing',
        () async {
      const link = ConnectLink(
        hosts: ['203.0.113.7:52741'],
        deviceId: 'ffffffff-0000-7000-8000-000000000001',
        deviceName: 'Phone X',
      );
      await expectLater(
        engine.syncWithLink(link.encode()),
        throwsA(isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.invalidCode,
        )),
      );
      expect(dialed, isEmpty);
      // Nothing was recorded as a sync either.
      expect(await alex.ledger.watchSyncRecords().first, isEmpty);
    });

    test('an invite with a public host joins without dialing', () async {
      final invite = InviteLink(
        groupId: groupIdOf(42),
        groupKey: Uint8List(32)..[0] = 7,
        groupName: 'Goa trip',
        currency: 'INR',
        fromName: 'Phone X',
        host: '203.0.113.7:52741',
      ).encode();
      final r = await engine.acceptInvite(invite);
      expect(r.alreadyMember, isFalse);
      expect(r.firstSync, isNull);
      expect(dialed, isEmpty);
      expect((await alex.ledger.groupKeys()).containsKey(groupIdOf(42)), isTrue);
      await expectLater(
        engine.syncWithLink(invite),
        throwsA(isA<SyncException>()),
      );
      expect(dialed, isEmpty);
    });
  });
}

/// Records the addresses the engine dials, and fails every dial.
final class _DialRecorder implements SyncTransport {
  _DialRecorder(this.dialed);
  final List<String> dialed;

  @override
  TransportKind get kind => TransportKind.lan;
  @override
  Future<TransportAvailability> availability() async =>
      TransportAvailability.ready;
  @override
  Future<TransportAvailability> requestPermissions() async =>
      TransportAvailability.ready;
  @override
  Future<void> startAdvertising(AdvertiseInfo info) async {}
  @override
  Future<void> stopAdvertising() async {}
  @override
  Stream<FrameChannel> get inbound => const Stream.empty();
  @override
  Stream<DiscoveredPeer> discover() => const Stream.empty();
  @override
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    dialed.add(peer.address);
    throw StateError('unreachable');
  }

  @override
  Future<void> dispose() async {}
}
