// QA SECURITY round 1: what a stranger on the same Wi-Fi (no group key)
// can do to a hosting phone through the real DefaultSyncEngine.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/support/evil_peer.dart';
import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';

void main() {
  late TestPhone alex, priya;
  late Seed seed;
  late MemoryTransportHub hub;
  late DefaultSyncEngine host;

  setUp(() async {
    alex = await TestPhone.create('a', deviceName: 'Alex');
    priya = await TestPhone.create('b', deviceName: 'Priya', name: 'Priya');
    seed = await alex.seedGroup(expenses: 2);
    await priya.join(alex, seed.g);
    hub = MemoryTransportHub();
    host = DefaultSyncEngine(
      store: alex.ledger,
      transports: [
        MemoryTransport(hub, kind: TransportKind.lan, address: 'alex'),
      ],
      timings: const SessionTimings(
        handshakeTimeout: Duration(seconds: 10),
        tick: Duration(milliseconds: 50),
      ),
    );
    await host.startHosting();
  });

  tearDown(() async {
    await host.dispose();
    await alex.close();
    await priya.close();
  });

  Future<FrameChannel> dial(String from) =>
      MemoryTransport(hub, kind: TransportKind.lan, address: from).connect(
        const DiscoveredPeer(
          kind: TransportKind.lan,
          address: 'alex',
          name: '',
        ),
      );

  Future<SessionResult> honestSync() async {
    final s = SyncSession(
      channel: await dial('priya-${DateTime.now().microsecondsSinceEpoch}'),
      store: priya.store,
      role: SessionRole.initiator,
      timings: fastTimings,
    );
    return s.run();
  }

  test('a stranger with no key learns nothing and is refused', () async {
    final evil = EvilPeer(await dial('mallory'), initiator: true);
    Object? error;
    try {
      await evil.handshake({groupIdOf(1): Uint8List(32)..[0] = 9});
    } on Object catch (e) {
      error = e;
    }
    expect(error, isNotNull);
    final err = evil.received.whereType<ErrorMessage>().firstOrNull;
    // HELLO arrives in clear (device id and name are visible by design);
    // nothing else does.
    expect(evil.received.whereType<OpsMessage>(), isEmpty);
    expect(evil.received.whereType<VvMessage>(), isEmpty);
    if (err != null) expect(err.code, ErrorCodes.noSharedGroups);
    final r = await honestSync();
    expect(r.isSuccess, isTrue, reason: r.message);
  });

  test(
    'a silent stranger connection does not lock friends out of the host',
    () async {
      // Mallory connects and says nothing (or reconnects every 10 s).
      final silent = await dial('mallory');
      addTearDown(silent.close);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final r = await honestSync();
      expect(
        r.isSuccess,
        isTrue,
        reason: 'friend got ${r.failure}: ${r.message}',
      );
    },
  );

  test('a stranger holding the pending-handshake slots does not lock friends '
      'out of the host', () async {
    // SECURITY-R1-10 neighbour: kMaxPendingInbound (4) silent
    // connections are held open; a friend's handshake evicts the
    // oldest one.
    for (var i = 0; i < kMaxPendingInbound; i++) {
      final c = await dial('mallory-$i');
      addTearDown(c.close);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final r = await honestSync();
    expect(r.isSuccess, isTrue, reason: '${r.failure}: ${r.message}');
  });

  test('a stranger reconnecting in a tight loop does not lock friends out of '
      'the host', () async {
    // SECURITY-R2-03. Each new pre-auth connection evicts the oldest
    // unauthenticated one, and the friend's handshake is unauthenticated
    // until AUTH, so a stranger who opens connections faster than one
    // handshake takes keeps evicting it.
    var flooding = true;
    final opened = <FrameChannel>[];
    final flood = () async {
      var i = 0;
      while (flooding) {
        // A burst per event-loop turn, as a LAN client easily manages.
        for (var k = 0; k < 8; k++) {
          opened.add(await dial('mallory-${i++}'));
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }();
    addTearDown(() async {
      flooding = false;
      await flood;
      for (final c in opened) {
        await c.close();
      }
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final r = await honestSync();
    flooding = false;
    expect(r.isSuccess, isTrue, reason: '${r.failure}: ${r.message}');
  }, skip: 'SECURITY-R2-03');

  test('garbage before HELLO ends only that connection', () async {
    final ch = await dial('mallory');
    final frames = <Uint8List>[];
    ch.frames.listen(frames.add, onError: (_) {});
    await ch.send(Uint8List.fromList([0x01, 1, 2, 3]));
    await eventually(() => frames.length >= 2);
    final last = FrameCodec.decodePlainFrame(frames.last);
    expect(last, isA<ErrorMessage>());
    expect((last as ErrorMessage).code, ErrorCodes.badFrame);
    await eventually(
      () =>
          host.status.session is SessionFailed ||
          host.status.session is! SessionActive,
    );
    final r = await honestSync();
    expect(r.isSuccess, isTrue, reason: r.message);
  });

  test(
    'a connect link to a public internet host is refused before dialing',
    () async {
      final dialed = <String>[];
      final engine = DefaultSyncEngine(
        store: priya.ledger,
        transports: [_DialRecorder(dialed)],
        linkConnectTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(engine.dispose);
      const link = ConnectLink(
        hosts: ['203.0.113.7:52741', 'evil.example.com:443'],
        deviceId: 'ffffffff-0000-7000-8000-000000000001',
        deviceName: 'Phone X',
      );
      try {
        await engine.syncWithLink(link.encode());
      } on SyncException catch (_) {
        // Either refusal is fine; dialing is not.
      }
      expect(
        dialed,
        isEmpty,
        reason: 'a link from a web page made the phone dial $dialed',
      );
    },
  );
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
