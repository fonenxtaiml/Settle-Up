// QA SECURITY round 1: the session crypto against SPEC 8.2 to 8.4,
// re-derived independently with package:cryptography and checked against
// a real responder SyncSession backed by the real Ledger.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/sync/crypto/aead.dart';
import 'package:settle_up/sync/crypto/handshake.dart';
import 'package:settle_up/sync/crypto/tokens.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/support/evil_peer.dart';
import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';

final _x25519 = X25519();
final _sha256 = Sha256();
final _hmac = Hmac.sha256();

Future<Uint8List> hmac(List<int> key, List<int> data) async => Uint8List.fromList(
    (await _hmac.calculateMac(data, secretKey: SecretKeyData(key))).bytes);

Future<Uint8List> sha(List<int> data) async =>
    Uint8List.fromList((await _sha256.hash(data)).bytes);

Uint8List nonceFor(int counter) {
  final n = Uint8List(12);
  ByteData.sublistView(n).setUint64(4, counter);
  return n;
}

/// AES-256-GCM seal per SPEC 8.2, written from the spec, not from aead.dart.
Future<Uint8List> specSeal(List<int> key, int counter, List<int> plain) async {
  final box = await AesGcm.with256bits().encrypt(plain,
      secretKey: SecretKeyData(key), nonce: nonceFor(counter));
  return Uint8List.fromList(
      [0x01, ...nonceFor(counter), ...box.cipherText, ...box.mac.bytes]);
}

Future<Uint8List> specOpen(List<int> key, Uint8List frame) async {
  final nonce = frame.sublist(1, 13);
  final ct = frame.sublist(13, frame.length - 16);
  final tag = frame.sublist(frame.length - 16);
  return Uint8List.fromList(await AesGcm.with256bits().decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(tag)),
      secretKey: SecretKeyData(key)));
}

/// A hand-built initiator that knows its own ephemeral private key, so the
/// test can compute every SPEC 8.4 value itself.
final class SpecInitiator {
  SpecInitiator(this.channel) {
    _sub = channel.frames.listen((f) {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(f);
      } else {
        _inbox.add(f);
      }
    }, onDone: () {
      closed.complete();
      for (final w in _waiters) {
        w.completeError(StateError('closed'));
      }
    });
  }

  final FrameChannel channel;
  late final StreamSubscription<Uint8List> _sub;
  final List<Uint8List> _inbox = [];
  final List<Completer<Uint8List>> _waiters = [];
  final Completer<void> closed = Completer();

  late SimpleKeyPair eph;
  late Uint8List nonce;
  late Uint8List helloFrame;
  late Uint8List peerHelloFrame;
  late HelloMessage peerHello;
  late Uint8List kIR, kRI, kAuth, transcript;
  late List<GroupId> shared;

  Future<Uint8List> next() {
    if (_inbox.isNotEmpty) return Future.value(_inbox.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future;
  }

  Future<void> hello(Map<GroupId, Uint8List> keys) async {
    eph = await _x25519.newKeyPair();
    final pub = await eph.extractPublicKey();
    final r = Random.secure();
    nonce = Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
    final blinded = <Uint8List>[];
    for (final k in keys.values) {
      final mac =
          await hmac(k, [...utf8.encode('settleup-gid-v1'), ...nonce]);
      blinded.add(mac.sublist(0, 16));
    }
    helloFrame = FrameCodec.plainFrame(HelloMessage(
      deviceId: 'ssssssss-0000-7000-8000-000000000001',
      deviceName: 'Spec',
      ephemeralPublicKey: Uint8List.fromList(pub.bytes),
      nonce: nonce,
      blindedGroups: blinded,
      maxFrame: channel.maxFrameBytes,
      transport: channel.kind,
    ));
    await channel.send(helloFrame);
    peerHelloFrame = await next();
    peerHello = FrameCodec.decodePlainFrame(peerHelloFrame) as HelloMessage;

    // S: my groups whose blind(g, peer.nonce) is in peer.groups, sorted.
    final theirs = {for (final b in peerHello.blindedGroups) base64.encode(b)};
    shared = [
      for (final e in keys.entries)
        if (theirs.contains(base64.encode((await hmac(e.value,
                [...utf8.encode('settleup-gid-v1'), ...peerHello.nonce]))
            .sublist(0, 16))))
          e.key,
    ]..sort();

    final dh = await (await _x25519.sharedSecretKey(
      keyPair: eph,
      remotePublicKey: SimplePublicKey(peerHello.ephemeralPublicKey,
          type: KeyPairType.x25519),
    ))
        .extractBytes();
    final ikm = [...dh, for (final g in shared) ...keys[g]!];
    final okm = await (await Hkdf(hmac: Hmac.sha256(), outputLength: 96)
            .deriveKey(
      secretKey: SecretKeyData(ikm),
      nonce: [...nonce, ...peerHello.nonce],
      info: utf8.encode('settleup-sync-v1|${shared.join(',')}'),
    ))
        .extractBytes();
    kIR = Uint8List.fromList(okm.sublist(0, 32));
    kRI = Uint8List.fromList(okm.sublist(32, 64));
    kAuth = Uint8List.fromList(okm.sublist(64, 96));
    transcript = await sha([...helloFrame, ...peerHelloFrame]);
  }

  Future<void> close() async {
    await _sub.cancel();
    await channel.close();
  }
}

void main() {
  late TestPhone priya, alex;
  late Seed seed;

  setUp(() async {
    alex = await TestPhone.create('a', deviceName: 'Alex');
    priya = await TestPhone.create('b', deviceName: 'Priya', name: 'Priya');
    seed = await alex.seedGroup(expenses: 1);
    await priya.join(alex, seed.g);
  });

  tearDown(() async {
    await alex.close();
    await priya.close();
  });

  Future<(SpecInitiator, Future<SessionResult>, SyncSession)> victim() async {
    final (ci, cr) = await channelPair();
    final session = SyncSession(
      channel: cr,
      store: priya.store,
      role: SessionRole.responder,
      timings: fastTimings,
    );
    final result = session.run();
    return (SpecInitiator(ci), result, session);
  }

  group('SPEC 8.4 key schedule, derived independently', () {
    test('the responder AUTH mac, k_RI and k_IR all match the spec formula',
        () async {
      final (spec, result, session) = await victim();
      await spec.hello({seed.g: await alex.keyOf(seed.g)});
      expect(spec.shared, [seed.g]);

      // Responder AUTH = HMAC(k_auth, "R" || transcript).
      final auth = FrameCodec.decodePlainFrame(await spec.next()) as AuthMessage;
      expect(auth.mac,
          await hmac(spec.kAuth, [...utf8.encode('R'), ...spec.transcript]));
      // Our AUTH with "I".
      await spec.channel.send(FrameCodec.plainFrame(AuthMessage(
          mac: await hmac(
              spec.kAuth, [...utf8.encode('I'), ...spec.transcript]))));

      // The responder's first sealed frame: counter 0 under k_RI.
      final first = await spec.next();
      expect(first[0], 0x01);
      expect(first.sublist(1, 13), nonceFor(0));
      final vv = FrameCodec.decodePlain(await specOpen(spec.kRI, first));
      expect(vv, isA<VvMessage>());
      expect((vv as VvMessage).groupId, seed.g);

      // A frame we seal with k_IR, counter 0, is accepted.
      await spec.channel.send(await specSeal(spec.kIR, 0,
          FrameCodec.encodePlain(VvMessage(groupId: seed.g, vv: (await alex.ledger.versionVector(seed.g))))));
      await spec.channel.send(await specSeal(
          spec.kIR, 1, FrameCodec.encodePlain(DoneMessage(groupId: seed.g))));
      await eventually(() => session.state == SessionState.exchanging);

      // SAS = u32be(SHA-256("settleup-sas" || transcript)[0..4]) % 10^6.
      final sas = await sha([...utf8.encode('settleup-sas'), ...spec.transcript]);
      final code = ByteData.sublistView(sas).getUint32(0) % 1000000;
      expect(session.verificationCode, code.toString().padLeft(6, '0'));
      await spec.close();
      await result;
    });

    test('a frame sealed with the wrong direction key fails authFailed',
        () async {
      final (spec, result, _) = await victim();
      await spec.hello({seed.g: await alex.keyOf(seed.g)});
      await spec.next(); // AUTH
      await spec.channel.send(FrameCodec.plainFrame(AuthMessage(
          mac: await hmac(
              spec.kAuth, [...utf8.encode('I'), ...spec.transcript]))));
      await spec.next(); // VV
      // Reflection: seal with k_RI (the responder's own send key).
      await spec.channel.send(await specSeal(spec.kRI, 0,
          FrameCodec.encodePlain(DoneMessage(groupId: seed.g))));
      final r = await result;
      expect(r.failure, SyncFailure.authFailed);
      expect(r.receivedOps, 0);
    });

    test('AUTH computed with the responder role label is refused '
        '(no reflection)', () async {
      final (spec, result, _) = await victim();
      await spec.hello({seed.g: await alex.keyOf(seed.g)});
      final theirs =
          FrameCodec.decodePlainFrame(await spec.next()) as AuthMessage;
      // Echo the responder's own AUTH back.
      await spec.channel.send(FrameCodec.plainFrame(theirs));
      final r = await result;
      expect(r.failure, SyncFailure.authFailed);
    });

    test('a replayed sealed frame (same counter) closes the session',
        () async {
      final (spec, result, _) = await victim();
      await spec.hello({seed.g: await alex.keyOf(seed.g)});
      await spec.next();
      await spec.channel.send(FrameCodec.plainFrame(AuthMessage(
          mac: await hmac(
              spec.kAuth, [...utf8.encode('I'), ...spec.transcript]))));
      await spec.next();
      final ping =
          await specSeal(spec.kIR, 0, FrameCodec.encodePlain(const PingMessage(1)));
      await spec.channel.send(ping);
      await spec.channel.send(ping); // replay
      final r = await result;
      expect(r.failure, SyncFailure.authFailed);
    });

    test('a skipped counter (reordering or a dropped frame) closes the '
        'session', () async {
      final (spec, result, _) = await victim();
      await spec.hello({seed.g: await alex.keyOf(seed.g)});
      await spec.next();
      await spec.channel.send(FrameCodec.plainFrame(AuthMessage(
          mac: await hmac(
              spec.kAuth, [...utf8.encode('I'), ...spec.transcript]))));
      await spec.next();
      await spec.channel.send(await specSeal(
          spec.kIR, 1, FrameCodec.encodePlain(const PingMessage(1))));
      expect((await result).failure, SyncFailure.authFailed);
    });

    test('an all-zero (low order) ephemeral key is refused', () async {
      final (ci, cr) = await channelPair();
      final session = SyncSession(
        channel: cr,
        store: priya.store,
        role: SessionRole.responder,
        timings: fastTimings,
      );
      final result = session.run();
      final evil = EvilPeer(ci, initiator: true);
      final peerHello = await evil.nextFrame();
      final ph = FrameCodec.decodePlainFrame(peerHello) as HelloMessage;
      final key = await alex.keyOf(seed.g);
      final nonce = Uint8List(16)..[0] = 7;
      await ci.send(FrameCodec.plainFrame(HelloMessage(
        deviceId: 'zzzzzzzz-0000-7000-8000-000000000001',
        deviceName: 'Zero',
        ephemeralPublicKey: Uint8List(32),
        nonce: nonce,
        blindedGroups: [await DiscoveryTokens.blind(key, nonce)],
        maxFrame: 1 << 20,
        transport: TransportKind.lan,
      )));
      expect(ph.ephemeralPublicKey, hasLength(32));
      final r = await result;
      expect(r.failure, isNot(isNull));
      expect(session.verificationCode, isNull);
    });
  });

  group('ephemeral and fresh per session', () {
    test('every HELLO carries a new X25519 key and a new 16-byte nonce',
        () async {
      final keys = {seed.g: await alex.keyOf(seed.g)};
      final ephs = <String>{};
      final nonces = <String>{};
      final blinded = <String>{};
      for (var i = 0; i < 20; i++) {
        final hs = await Handshake.start(
          initiator: true,
          groupKeys: keys,
          deviceId: alex.deviceId,
          deviceName: 'Alex',
          maxFrame: 1 << 20,
          transport: TransportKind.lan,
        );
        expect(hs.hello.nonce, hasLength(16));
        ephs.add(base64.encode(hs.hello.ephemeralPublicKey));
        nonces.add(base64.encode(hs.hello.nonce));
        blinded.add(base64.encode(hs.hello.blindedGroups.single));
      }
      expect(ephs, hasLength(20));
      expect(nonces, hasLength(20));
      // Blinded ids depend on the nonce, so they are unlinkable too.
      expect(blinded, hasLength(20));
    });

    test('two real sessions between the same phones derive different keys',
        () async {
      final fingerprints = <String>{};
      for (var i = 0; i < 2; i++) {
        final keys = {seed.g: await alex.keyOf(seed.g)};
        final a = await Handshake.start(
            initiator: true,
            groupKeys: keys,
            deviceId: alex.deviceId,
            deviceName: 'A',
            maxFrame: 1 << 20,
            transport: TransportKind.lan);
        final b = await Handshake.start(
            initiator: false,
            groupKeys: keys,
            deviceId: priya.deviceId,
            deviceName: 'B',
            maxFrame: 1 << 20,
            transport: TransportKind.lan);
        final ka =
            await a.onPeerHello(b.hello, b.helloFrame, localMaxFrame: 1 << 20);
        final kb =
            await b.onPeerHello(a.hello, a.helloFrame, localMaxFrame: 1 << 20);
        expect(ka.keyFingerprint, kb.keyFingerprint);
        fingerprints.add(ka.keyFingerprint);
      }
      expect(fingerprints, hasLength(2));
    });

    test('HELLO JSON never contains a group id or a group key', () async {
      final key = await alex.keyOf(seed.g);
      final hs = await Handshake.start(
        initiator: true,
        groupKeys: {seed.g: key},
        deviceId: alex.deviceId,
        deviceName: 'Alex',
        maxFrame: 1 << 20,
        transport: TransportKind.lan,
      );
      final text = latin1.decode(hs.helloFrame, allowInvalid: true);
      expect(text, isNot(contains(seed.g)));
      for (final form in keyForms(key)) {
        expect(text, isNot(contains(form)));
      }
    });
  });

  group('FrameCipher', () {
    Future<(FrameCipher, FrameCipher)> pair() async {
      final r = Random(3);
      final k1 = List.generate(32, (_) => r.nextInt(256));
      final k2 = List.generate(32, (_) => r.nextInt(256));
      return (
        FrameCipher(sendKey: k1, receiveKey: k2),
        FrameCipher(sendKey: k2, receiveKey: k1),
      );
    }

    test('nonces are 0x00000000 || counter and never repeat in a direction',
        () async {
      final (a, _) = await pair();
      final seen = <String>{};
      for (var i = 0; i < 2000; i++) {
        final f = await a.seal(Uint8List.fromList([7, 0, 0x7b, 0x7d]));
        final nonce = f.sublist(1, 13);
        expect(nonce.sublist(0, 4), [0, 0, 0, 0]);
        expect(ByteData.sublistView(nonce).getUint64(4), i);
        expect(seen.add(base64.encode(nonce)), isTrue);
      }
    });

    test('the two directions use different keys (same counter, different '
        'ciphertext)', () async {
      final (a, b) = await pair();
      final plain = Uint8List.fromList([7, 0, 0x7b, 0x7d]);
      final fa = await a.seal(plain);
      final fb = await b.seal(plain);
      expect(fa.sublist(1, 13), fb.sublist(1, 13));
      expect(fa.sublist(13), isNot(fb.sublist(13)));
      await expectLater(a.open(fa), throwsA(isA<FrameAuthException>()));
    });

    test('tag, ciphertext, nonce prefix and truncation tampering are all '
        'refused without advancing the counter', () async {
      final (a, b) = await pair();
      final good = await a.seal(Uint8List.fromList([7, 0, 0x7b, 0x7d]));
      Uint8List flip(int index) =>
          Uint8List.fromList(good)..[index] ^= 0x01;
      final bad = <String, Uint8List>{
        'last tag byte': flip(good.length - 1),
        'first tag byte': flip(good.length - 16),
        'ciphertext': flip(13),
        'nonce prefix': flip(1),
        'nonce counter': flip(12),
        'truncated tag': Uint8List.sublistView(good, 0, good.length - 1),
        'plain kind byte': Uint8List.fromList(good)..[0] = 0x00,
        'too short': Uint8List.fromList(good.sublist(0, 20)),
      };
      for (final MapEntry(key: what, value: frame) in bad.entries) {
        await expectLater(b.open(frame), throwsA(isA<FrameAuthException>()),
            reason: what);
        expect(b.receivedFrames, 0, reason: what);
      }
      expect(await b.open(good), [7, 0, 0x7b, 0x7d]);
      expect(b.receivedFrames, 1);
    });

    test('constantTimeEquals', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2, 3], [9, 2, 3]), isFalse);
      expect(constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
      expect(constantTimeEquals([], []), isTrue);
      // Values above a byte must not alias (e.g. 256 vs 0).
      expect(constantTimeEquals([256], [0]), isFalse);
    });
  });

  group('SPEC 8.3 tokens and blinded ids', () {
    test('token and blind match the spec formulas', () async {
      final key = await alex.keyOf(seed.g);
      final w = DiscoveryTokens.windowAt(DateTime.utc(2026, 11, 9, 10));
      expect(w, DateTime.utc(2026, 11, 9, 10).millisecondsSinceEpoch ~/ 1000 ~/ 600);
      final mac = await hmac(key, utf8.encode('settleup-adv-v1:$w'));
      final hex =
          mac.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(await DiscoveryTokens.token(key, w), hex.substring(0, 16));
      final nonce = Uint8List.fromList(List.generate(16, (i) => i));
      final blind =
          await hmac(key, [...utf8.encode('settleup-gid-v1'), ...nonce]);
      expect(await DiscoveryTokens.blind(key, nonce), blind.sublist(0, 16));
    });

    test('tokens change every 10 minutes and scanners accept only the '
        'current and previous window', () async {
      final key = await alex.keyOf(seed.g);
      final t0 = DateTime.utc(2026, 11, 9, 10, 0, 1);
      final a = await DiscoveryTokens.advertised({seed.g: key}, t0);
      final b = await DiscoveryTokens.advertised(
          {seed.g: key}, t0.add(const Duration(minutes: 10)));
      expect(a.single, isNot(b.single));
      final idx = await DiscoveryTokens.index({seed.g: key}, t0);
      final w = DiscoveryTokens.windowAt(t0);
      expect(idx.keys,
          unorderedEquals([await DiscoveryTokens.token(key, w),
              await DiscoveryTokens.token(key, w - 1)]));
      expect(idx.containsKey(await DiscoveryTokens.token(key, w - 2)), isFalse);
    });

    test('a hosting engine re-advertises fresh tokens when the window '
        'changes', () async {
      final base = DateTime.utc(2026, 11, 9, 10, 9, 59, 500);
      final clock = _RunningClock(base);
      final t = _RecordingTransport();
      final engine = DefaultSyncEngine(
        store: alex.ledger,
        transports: [t],
        clock: clock,
      );
      addTearDown(engine.dispose);
      await engine.startHosting();
      expect(t.advertised, hasLength(1));
      final first = t.advertised.single.groupTokens;
      final ok = await eventually(() => t.advertised.length >= 2,
          timeout: const Duration(seconds: 4));
      expect(ok, isTrue, reason: 'no re-advertise after the window changed');
      final second = t.advertised.last.groupTokens;
      expect(second, isNot(first));
      final key = await alex.keyOf(seed.g);
      expect(second, [
        await DiscoveryTokens.token(
            key, DiscoveryTokens.windowAt(base) + 1),
      ]);
      // Advertised data carries no key and no group id.
      for (final info in t.advertised) {
        final all = '${info.deviceName} ${info.groupTokens.join(',')}';
        expect(all, isNot(contains(seed.g)));
        for (final form in keyForms(key)) {
          expect(all, isNot(contains(form)));
        }
      }
    });
  });

  test('the host connect link carries no group key, token or group id',
      () async {
    final t = _RecordingTransport();
    final engine = DefaultSyncEngine(store: alex.ledger, transports: [t]);
    addTearDown(engine.dispose);
    final host = await engine.startHosting();
    final key = await alex.keyOf(seed.g);
    final link = Uri.decodeFull(host.connectLink);
    expect(link, startsWith('settleup://sync?v=1'));
    expect(link, isNot(contains(seed.g)));
    expect(link, isNot(contains('k=')));
    for (final form in keyForms(key)) {
      expect(link, isNot(contains(form)));
    }
    for (final token in t.advertised.single.groupTokens) {
      expect(link, isNot(contains(token)));
    }
  });
}

/// Every common text form of a key (to grep logs, links and files).
List<String> keyForms(List<int> key) {
  final b64 = base64.encode(key);
  final b64url = base64Url.encode(key);
  return [
    b64,
    b64.replaceAll('=', ''),
    b64url,
    b64url.replaceAll('=', ''),
    key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
    key.join(','),
  ];
}

final class _RunningClock implements SyncClock {
  _RunningClock(this.base);
  final DateTime base;
  final Stopwatch _sw = Stopwatch()..start();
  @override
  DateTime now() => base.add(_sw.elapsed);
}

/// A transport that only records what the engine advertises.
final class _RecordingTransport implements SyncTransport {
  final List<AdvertiseInfo> advertised = [];
  final StreamController<FrameChannel> _inbound = StreamController.broadcast();

  @override
  TransportKind get kind => TransportKind.lan;
  @override
  Future<TransportAvailability> availability() async =>
      TransportAvailability.ready;
  @override
  Future<TransportAvailability> requestPermissions() async =>
      TransportAvailability.ready;
  @override
  Future<void> startAdvertising(AdvertiseInfo info) async =>
      advertised.add(info);
  @override
  Future<void> stopAdvertising() async {}
  @override
  Stream<FrameChannel> get inbound => _inbound.stream;
  @override
  Stream<DiscoveredPeer> discover() => const Stream.empty();
  @override
  Future<FrameChannel> connect(DiscoveredPeer peer,
          {Duration timeout = const Duration(seconds: 10)}) =>
      Future.error(StateError('no connect'));
  @override
  Future<void> dispose() => _inbound.close();
}
