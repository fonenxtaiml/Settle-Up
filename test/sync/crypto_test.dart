import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/crypto/aead.dart';
import 'package:settle_up/sync/crypto/handshake.dart';
import 'package:settle_up/sync/crypto/tokens.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';

import 'support/harness.dart';
import 'support/phone.dart';

Uint8List _key(int seed) => groupKeyOf(seed);

Future<Handshake> _start(
  bool initiator,
  Map<String, Uint8List> keys, {
  String id = 'dev',
}) => Handshake.start(
  initiator: initiator,
  groupKeys: keys,
  deviceId: '$id-0000',
  deviceName: id,
  maxFrame: 16384,
  transport: TransportKind.lan,
  random: Random(initiator ? 1 : 2),
);

/// Runs both halves of the handshake in memory.
Future<(HandshakeKeys, HandshakeKeys)> _handshake(
  Map<String, Uint8List> i,
  Map<String, Uint8List> r,
) async {
  final hi = await _start(true, i, id: 'ini');
  final hr = await _start(false, r, id: 'res');
  final ki = await hi.onPeerHello(
    hr.hello,
    hr.helloFrame,
    localMaxFrame: 1 << 20,
  );
  final kr = await hr.onPeerHello(
    hi.hello,
    hi.helloFrame,
    localMaxFrame: 16384,
  );
  return (ki, kr);
}

void main() {
  group('handshake', () {
    test('1 shared group: equal keys, matching code, macs verify', () async {
      final (ki, kr) = await _handshake({'g1': _key(1)}, {'g1': _key(1)});
      expect(ki.sharedGroups, ['g1']);
      expect(kr.sharedGroups, ['g1']);
      expect(ki.keyFingerprint, kr.keyFingerprint);
      expect(ki.verificationCode, kr.verificationCode);
      expect(ki.verificationCode, matches(RegExp(r'^\d{6}$')));
      expect(ki.maxFrame, 16384);
      expect(kr.maxFrame, 16384);
      expect(ki.verifyPeerMac(kr.myMac), isTrue);
      expect(kr.verifyPeerMac(ki.myMac), isTrue);
      // Role-bound macs: no reflection.
      expect(ki.verifyPeerMac(ki.myMac), isFalse);
      expect(kr.verifyPeerMac(kr.myMac), isFalse);

      final frame = await ki.cipher.seal(
        FrameCodec.encodePlain(const ByeMessage()),
      );
      final plain = await kr.cipher.open(frame);
      expect(FrameCodec.decodePlain(plain), isA<ByeMessage>());
    });

    test('3 shared groups out of partially overlapping sets', () async {
      final (ki, kr) = await _handshake(
        {'g3': _key(3), 'g1': _key(1), 'g2': _key(2), 'g9': _key(9)},
        {'g2': _key(2), 'g3': _key(3), 'g1': _key(1), 'g7': _key(7)},
      );
      expect(ki.sharedGroups, ['g1', 'g2', 'g3']);
      expect(kr.sharedGroups, ['g1', 'g2', 'g3']);
      expect(ki.keyFingerprint, kr.keyFingerprint);
      expect(ki.verificationCode, kr.verificationCode);
    });

    test('a different key for the same group id shares nothing', () async {
      expect(
        () => _handshake({'g1': _key(1)}, {'g1': _key(2)}),
        throwsA(
          isA<HandshakeException>().having(
            (e) => e.code,
            'code',
            ErrorCodes.noSharedGroups,
          ),
        ),
      );
    });

    test('incompatible protocol versions are refused', () async {
      final hi = await _start(true, {'g1': _key(1)});
      final hr = await _start(false, {'g1': _key(1)});
      final future = HelloMessage(
        deviceId: 'x',
        deviceName: 'x',
        ephemeralPublicKey: hr.hello.ephemeralPublicKey,
        nonce: hr.hello.nonce,
        blindedGroups: hr.hello.blindedGroups,
        maxFrame: 1000,
        transport: TransportKind.lan,
        proto: 3,
        minProto: 2,
      );
      expect(
        () => hi.onPeerHello(
          future,
          FrameCodec.plainFrame(future),
          localMaxFrame: 1000,
        ),
        throwsA(
          isA<HandshakeException>().having(
            (e) => e.code,
            'code',
            ErrorCodes.protoUnsupported,
          ),
        ),
      );
    });

    test('a peer announcing a tiny max frame is refused', () async {
      final hi = await _start(true, {'g1': _key(1)});
      final hr = await _start(false, {'g1': _key(1)});
      final tiny = HelloMessage(
        deviceId: 'x',
        deviceName: 'x',
        ephemeralPublicKey: hr.hello.ephemeralPublicKey,
        nonce: hr.hello.nonce,
        blindedGroups: hr.hello.blindedGroups,
        maxFrame: kMinFrameBytes - 1,
        transport: TransportKind.ble,
      );
      expect(
        () => hi.onPeerHello(
          tiny,
          FrameCodec.plainFrame(tiny),
          localMaxFrame: 1 << 20,
        ),
        throwsA(
          isA<HandshakeException>().having(
            (e) => e.code,
            'code',
            ErrorCodes.badFrame,
          ),
        ),
      );
    });

    test('HELLOs carry no group ids in clear and blind per nonce', () async {
      final a = await _start(true, {'g1': _key(1)});
      final b = await _start(false, {'g1': _key(1)});
      final text = String.fromCharCodes(a.helloFrame);
      expect(text, isNot(contains('g1')));
      expect(a.hello.blindedGroups.single, isNot(b.hello.blindedGroups.single));
    });
    test('more shared groups than fit in a HELLO still agree on S', () async {
      final keys = {for (var i = 0; i < 300; i++) groupIdOf(i): groupKeyOf(i)};
      final hi = await Handshake.start(
        initiator: true,
        groupKeys: keys,
        deviceId: deviceIdOf('a'),
        deviceName: 'A',
        maxFrame: 1 << 20,
        transport: TransportKind.lan,
        random: Random(1),
      );
      final hr = await Handshake.start(
        initiator: false,
        groupKeys: keys,
        deviceId: deviceIdOf('b'),
        deviceName: 'B',
        maxFrame: 1 << 20,
        transport: TransportKind.lan,
        random: Random(2),
      );
      expect(hi.hello.blindedGroups, hasLength(kMaxHelloGroups));
      final ki = await hi.onPeerHello(
        hr.hello,
        hr.helloFrame,
        localMaxFrame: 1 << 20,
      );
      final kr = await hr.onPeerHello(
        hi.hello,
        hi.helloFrame,
        localMaxFrame: 1 << 20,
      );
      expect(ki.sharedGroups, kr.sharedGroups);
      expect(ki.sharedGroups, isNotEmpty);
      expect(ki.keyFingerprint, kr.keyFingerprint);
      expect(kr.verifyPeerMac(ki.myMac), isTrue);
    });
  });

  group('FrameCipher', () {
    late FrameCipher alice, bob;
    setUp(() {
      final k1 = _key(10), k2 = _key(11);
      alice = FrameCipher(sendKey: k1, receiveKey: k2);
      bob = FrameCipher(sendKey: k2, receiveKey: k1);
    });

    Uint8List plain(int n) => FrameCodec.encodePlain(PingMessage(n));

    test('frames open in order and nonces count up from 0', () async {
      final f0 = await alice.seal(plain(0));
      final f1 = await alice.seal(plain(1));
      expect(f0[0], FrameKind.sealed);
      expect(f0.sublist(1, 13), List.filled(12, 0));
      expect(f1.sublist(1, 13), [...List.filled(11, 0), 1]);
      expect(f0.length, plain(0).length + kSealOverhead);
      expect((FrameCodec.decodePlain(await bob.open(f0)) as PingMessage).t, 0);
      expect((FrameCodec.decodePlain(await bob.open(f1)) as PingMessage).t, 1);
    });

    test(
      'replayed, reordered, tampered and foreign frames are rejected',
      () async {
        final f0 = await alice.seal(plain(0));
        final f1 = await alice.seal(plain(1));
        final f2 = await alice.seal(plain(2));
        await expectLater(bob.open(f1), throwsA(isA<FrameAuthException>()));
        await bob.open(f0);
        await expectLater(bob.open(f0), throwsA(isA<FrameAuthException>()));
        final tampered = Uint8List.fromList(f1)..[20] ^= 0x01;
        await expectLater(
          bob.open(tampered),
          throwsA(isA<FrameAuthException>()),
        );
        final badTag = Uint8List.fromList(f1)..[f1.length - 1] ^= 0x80;
        await expectLater(bob.open(badTag), throwsA(isA<FrameAuthException>()));
        // Bob's own frames do not open with his receive key.
        await expectLater(
          bob.open(await bob.seal(plain(9))),
          throwsA(isA<FrameAuthException>()),
        );
        await bob.open(f1);
        await bob.open(f2);
        expect(bob.receivedFrames, 3);
      },
    );

    test('a nonce with a non-zero prefix is rejected', () async {
      final f0 = await alice.seal(plain(0));
      final bad = Uint8List.fromList(f0)..[1] = 1;
      await expectLater(bob.open(bad), throwsA(isA<FrameAuthException>()));
      await expectLater(
        bob.open(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FrameAuthException>()),
      );
    });

    test('constant-time compare', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
      expect(constantTimeEquals([], []), isTrue);
    });
  });

  group('tokens', () {
    final t0 = DateTime.utc(2026, 11, 9, 12, 0, 1);

    test(
      '16 hex chars, stable per window, rotating every 10 minutes',
      () async {
        final w = DiscoveryTokens.windowAt(t0);
        final a = await DiscoveryTokens.token(_key(1), w);
        expect(a, matches(RegExp(r'^[0-9a-f]{16}$')));
        expect(await DiscoveryTokens.token(_key(1), w), a);
        expect(await DiscoveryTokens.token(_key(1), w + 1), isNot(a));
        expect(await DiscoveryTokens.token(_key(2), w), isNot(a));
        expect(
          DiscoveryTokens.windowAt(t0.add(const Duration(minutes: 10))),
          w + 1,
        );
        expect(DiscoveryTokens.nextWindowStart(t0).isAfter(t0), isTrue);
        expect(
          DiscoveryTokens.windowAt(DiscoveryTokens.nextWindowStart(t0)),
          w + 1,
        );
      },
    );

    test(
      'a scanner matches the current and the previous window only',
      () async {
        final keys = {'g1': _key(1), 'g2': _key(2)};
        final adv = await DiscoveryTokens.advertised(keys, t0);
        expect(adv, hasLength(2));
        expect([...adv]..sort(), adv);
        final later = await DiscoveryTokens.index(
          keys,
          t0.add(const Duration(minutes: 10)),
        );
        expect(adv.map((t) => later[t]).toSet(), {'g1', 'g2'});
        final muchLater = await DiscoveryTokens.index(
          keys,
          t0.add(const Duration(minutes: 20)),
        );
        expect(adv.where(muchLater.containsKey), isEmpty);
        final stranger = await DiscoveryTokens.index({'g3': _key(3)}, t0);
        expect(adv.where(stranger.containsKey), isEmpty);
      },
    );

    test('blinded ids depend on the key and the nonce', () async {
      final n1 = Uint8List(16), n2 = Uint8List(16)..[0] = 1;
      final a = await DiscoveryTokens.blind(_key(1), n1);
      expect(a, hasLength(16));
      expect(await DiscoveryTokens.blind(_key(1), n1), a);
      expect(await DiscoveryTokens.blind(_key(1), n2), isNot(a));
      expect(await DiscoveryTokens.blind(_key(2), n1), isNot(a));
    });
  });

  group('over MemoryTransport', () {
    late TestPhone alex, priya;
    late List<GroupId> groups;
    setUp(() async {
      alex = await TestPhone.create('a');
      priya = await TestPhone.create('b', name: 'Priya');
      groups = [];
      for (var i = 0; i < 3; i++) {
        final g = (await alex.seedGroup(expenses: 1)).g;
        await priya.join(alex, g);
        groups.add(g);
      }
    });

    tearDown(() async {
      await alex.close();
      await priya.close();
    });

    test(
      '3 shared groups: both sides authenticate with the same code',
      () async {
        final (ra, rp) = await syncPair(alex, priya);
        expect(ra.outcome, SyncOutcome.completed);
        expect(ra.groupIds, hasLength(3));
        expect(ra.verificationCode, isNotNull);
        expect(ra.verificationCode, rp.verificationCode);
        expect(priya.canonical, alex.canonical);
      },
    );

    test('no shared groups -> noSharedGroups on both sides', () async {
      final stranger = await TestPhone.create('s');
      await stranger.seedGroup();
      final (ra, rs) = await syncPair(alex, stranger);
      expect(ra.failure, SyncFailure.noSharedGroups);
      expect(rs.failure, SyncFailure.noSharedGroups);
      expect(ra.outcome, SyncOutcome.failed);
      expect(stranger.opCount(groups.first), 0);
      await stranger.close();
    });

    /// Rewrites the first sealed frame the responder receives.
    List<Uint8List> Function(int, Uint8List) onFirstSealed(
      List<Uint8List> Function(Uint8List) f,
    ) {
      var done = false;
      return (i, frame) {
        if (done || frame[0] != FrameKind.sealed) return [frame];
        done = true;
        return f(frame);
      };
    }

    Future<void> expectAuthFailed(
      List<Uint8List> Function(int, Uint8List) transform,
    ) async {
      final (ra, rp) = await syncPair(
        alex,
        priya,
        wrapResponder: (c) => InterceptChannel(c, transform),
      );
      expect(rp.failure, SyncFailure.authFailed, reason: rp.message);
      expect(ra.isSuccess, isFalse);
      expect(priya.opCount(groups.first), 0);
    }

    test('tampered ciphertext closes the session', () async {
      await expectAuthFailed(
        onFirstSealed((f) => [Uint8List.fromList(f)..[f.length ~/ 2] ^= 0x04]),
      );
    });

    test('a replayed frame closes the session', () async {
      await expectAuthFailed(onFirstSealed((f) => [f, f]));
    });

    test('reordered frames close the session', () async {
      Uint8List? held;
      await expectAuthFailed((i, frame) {
        if (frame[0] != FrameKind.sealed) return [frame];
        if (held == null) {
          held = frame;
          return const [];
        }
        final first = held!;
        held = Uint8List(0);
        return first.isEmpty ? [frame] : [frame, first];
      });
    });

    test('a dropped sealed frame closes the session', () async {
      await expectAuthFailed(onFirstSealed((f) => const []));
    });

    test(
      'a captured HELLO replayed with a fresh key cannot authenticate',
      () async {
        // The attacker copies Alex's blinded ids and nonce (so Priya finds a
        // shared group) but has no group key, so it cannot produce AUTH.
        final (attacker, victimEnd) = await channelPair();
        final real = await Handshake.start(
          initiator: true,
          groupKeys: await alex.ledger.groupKeys(),
          deviceId: alex.deviceId,
          deviceName: 'Alex',
          maxFrame: 1 << 20,
          transport: TransportKind.lan,
        );
        final own = await Handshake.start(
          initiator: true,
          groupKeys: {'x': _key(99)},
          deviceId: 'mallory',
          deviceName: 'Mallory',
          maxFrame: 1 << 20,
          transport: TransportKind.lan,
        );
        final forged = HelloMessage(
          deviceId: alex.deviceId,
          deviceName: 'Alex',
          ephemeralPublicKey: own.hello.ephemeralPublicKey,
          nonce: real.hello.nonce,
          blindedGroups: real.hello.blindedGroups,
          maxFrame: 1 << 20,
          transport: TransportKind.lan,
        );
        final victim = SyncSession(
          channel: victimEnd,
          store: priya.store,
          role: SessionRole.responder,
          timings: fastTimings,
        );
        final received = <SyncMessage>[];
        final sub = attacker.frames.listen((f) {
          if (f[0] == FrameKind.plain) {
            received.add(FrameCodec.decodePlainFrame(f));
          }
        });
        final result = victim.run();
        await attacker.send(FrameCodec.plainFrame(forged));
        await attacker.send(
          FrameCodec.plainFrame(
            AuthMessage(mac: Uint8List.fromList(List.filled(32, 7))),
          ),
        );

        final r = await result;
        expect(r.failure, SyncFailure.authFailed);
        expect(priya.opCount(groups.first), 0);
        await eventually(() => received.whereType<ErrorMessage>().isNotEmpty);
        expect(
          received.whereType<ErrorMessage>().single.code,
          ErrorCodes.authFailed,
        );
        // The victim's own AUTH is useless to the attacker: it is bound to
        // a transcript containing the attacker's ephemeral key.
        expect(received.whereType<AuthMessage>(), hasLength(1));
        await sub.cancel();
      },
    );

    test(
      'a forged AUTH from a non-member fails in constant time compare',
      () async {
        final (ra, rp) = await syncPair(
          alex,
          priya,
          wrapResponder: (c) => InterceptChannel(c, (i, f) {
            if (f[0] != FrameKind.plain) return [f];
            final m = FrameCodec.decodePlainFrame(f);
            if (m is! AuthMessage) return [f];
            final mac = Uint8List.fromList(m.mac)..[0] ^= 1;
            return [FrameCodec.plainFrame(AuthMessage(mac: mac))];
          }),
        );
        expect(rp.failure, SyncFailure.authFailed);
        expect(ra.failure, isNotNull);
        expect(ra.isSuccess, isFalse);
      },
    );
  });

  test(
    'the session never applies ops before AUTH even if sent sealed',
    () async {
      // Covered structurally: frames before AUTH must be plain HELLO/AUTH/
      // ERROR. A plain OPS frame is refused.
      final alex = await TestPhone.create('a');
      final g = (await alex.seedGroup()).g;
      final (ci, cr) = await channelPair();
      unawaited(cr.frames.drain<void>());
      final s = SyncSession(
        channel: ci,
        store: alex.store,
        role: SessionRole.initiator,
        timings: fastTimings,
      );
      final f = s.run();
      await cr.send(
        FrameCodec.plainFrame(
          OpsMessage(
            groupId: g,
            batch: 1,
            total: 1,
            ops: alex.opsOf(g).take(1).toList(),
            more: false,
          ),
        ),
      );
      expect((await f).failure, SyncFailure.protocolMismatch);
      await alex.close();
    },
  );
}
