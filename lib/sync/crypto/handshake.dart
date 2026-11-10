// Per-connection handshake (SPEC 8.4), Noise-NNpsk-like:
//
//   dh   = X25519(myEphemeralPrivate, peerEphemeralPublic)
//   ikm  = dh || groupKey(S[0]) || groupKey(S[1]) || ...   (S sorted by id)
//   salt = nonce_I || nonce_R
//   info = "settleup-sync-v1|" + S.join(",")
//   okm  = HKDF-SHA256(ikm, salt, info, 96)
//   k_IR = okm[0..32]  k_RI = okm[32..64]  k_auth = okm[64..96]
//   transcript = SHA-256(helloFrame_I || helloFrame_R)
//   AUTH.mac   = HMAC-SHA256(k_auth, "I" | "R" || transcript)
//   code       = u32be(SHA-256("settleup-sas" || transcript)[0..4]) % 10^6
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:cryptography/cryptography.dart';
import 'package:meta/meta.dart';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../protocol/codec.dart';
import '../protocol/messages.dart';
import 'aead.dart';
import 'tokens.dart';

/// Smallest max frame size a peer may announce (fits any single op).
const int kMinFrameBytes = 4096;

/// A handshake failure; [code] is the `ERROR` code to send (ErrorCodes).
final class HandshakeException implements Exception {
  const HandshakeException(this.code, [this.message = '']);
  final String code;
  final String message;
  @override
  String toString() => 'HandshakeException($code: $message)';
}

/// One side of the handshake. Create it when the channel opens, send
/// [helloFrame], then call [onPeerHello] with the peer's HELLO.
final class Handshake {
  Handshake._({
    required this.initiator,
    required this._groupKeys,
    required this._keyPair,
    required this.hello,
    required this.helloFrame,
  });

  static final X25519 _x25519 = X25519();
  static final Sha256 _sha256 = Sha256();
  static final Hmac _hmac = Hmac.sha256();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 96);

  /// Builds our HELLO with a fresh ephemeral key pair and nonce.
  static Future<Handshake> start({
    required bool initiator,
    required Map<GroupId, Uint8List> groupKeys,
    required DeviceId deviceId,
    required String deviceName,
    required int maxFrame,
    required TransportKind transport,
    Random? random,
  }) async {
    final rnd = random ?? Random.secure();
    final keyPair = await _x25519.newKeyPair();
    final pub = await keyPair.extractPublicKey();
    final nonce = Uint8List.fromList(
      List<int>.generate(16, (_) => rnd.nextInt(256)),
    );
    // Shuffle so the order does not tie a blinded id to a group. Only the
    // groups that fit in the HELLO take part in S: the peer cannot match
    // the others, so counting them here would make the two sides disagree.
    final ids = groupKeys.keys.toList()..shuffle(rnd);
    final keys = {
      for (final g in ids.take(kMaxHelloGroups)) g: groupKeys[g]!,
    };
    final blinded = [
      for (final key in keys.values) await DiscoveryTokens.blind(key, nonce),
    ];
    final hello = HelloMessage(
      deviceId: deviceId,
      deviceName: helloDeviceName(deviceName),
      ephemeralPublicKey: Uint8List.fromList(pub.bytes),
      nonce: nonce,
      blindedGroups: blinded,
      maxFrame: maxFrame,
      transport: transport,
    );
    return Handshake._(
      initiator: initiator,
      groupKeys: keys,
      keyPair: keyPair,
      hello: hello,
      helloFrame: FrameCodec.plainFrame(hello),
    );
  }

  final bool initiator;
  final HelloMessage hello;

  /// The exact channel frame we send (part of the transcript).
  final Uint8List helloFrame;

  final Map<GroupId, Uint8List> _groupKeys;
  final SimpleKeyPair _keyPair;

  /// Negotiates the protocol, finds the shared groups and derives every
  /// session key. Throws [HandshakeException] with `proto_unsupported`,
  /// `no_shared_groups` or `bad_frame`.
  Future<HandshakeKeys> onPeerHello(
    HelloMessage peer,
    Uint8List peerHelloFrame, {
    required int localMaxFrame,
  }) async {
    final proto = min(hello.proto, peer.proto);
    if (proto < max(hello.minProto, peer.minProto)) {
      throw HandshakeException(
        ErrorCodes.protoUnsupported,
        'peer speaks ${peer.minProto}..${peer.proto}',
      );
    }

    if (peer.maxFrame < kMinFrameBytes) {
      throw HandshakeException(
          ErrorCodes.badFrame, 'maxFrame ${peer.maxFrame} is too small');
    }

    final peerBlinded = {for (final b in peer.blindedGroups) b64UrlEncode(b)};
    final shared = <GroupId>[];
    for (final e in _groupKeys.entries) {
      final mine = await DiscoveryTokens.blind(e.value, peer.nonce);
      if (peerBlinded.contains(b64UrlEncode(mine))) shared.add(e.key);
    }
    shared.sort();
    if (shared.isEmpty) {
      throw const HandshakeException(ErrorCodes.noSharedGroups);
    }

    final secret = await _x25519.sharedSecretKey(
      keyPair: _keyPair,
      remotePublicKey: SimplePublicKey(
        peer.ephemeralPublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final dh = await secret.extractBytes();
    if (dh.every((b) => b == 0)) {
      // Low-order peer point: the DH contributes nothing. Refuse.
      throw const HandshakeException(ErrorCodes.badFrame, 'weak ephemeral');
    }

    final ikm = BytesBuilder(copy: false)..add(dh);
    for (final g in shared) {
      ikm.add(_groupKeys[g]!);
    }
    final nonceI = initiator ? hello.nonce : peer.nonce;
    final nonceR = initiator ? peer.nonce : hello.nonce;
    final okmKey = await _hkdf.deriveKey(
      secretKey: SecretKeyData(ikm.takeBytes()),
      nonce: [...nonceI, ...nonceR],
      info: utf8.encode('settleup-sync-v1|${shared.join(',')}'),
    );
    final okm = Uint8List.fromList(await okmKey.extractBytes());
    final kIR = Uint8List.sublistView(okm, 0, 32);
    final kRI = Uint8List.sublistView(okm, 32, 64);
    final kAuth = Uint8List.sublistView(okm, 64, 96);

    final helloI = initiator ? helloFrame : peerHelloFrame;
    final helloR = initiator ? peerHelloFrame : helloFrame;
    final transcript = Uint8List.fromList(
      (await _sha256.hash([...helloI, ...helloR])).bytes,
    );

    Future<Uint8List> authMac(String role) async {
      final mac = await _hmac.calculateMac(
        [...utf8.encode(role), ...transcript],
        secretKey: SecretKeyData(kAuth),
      );
      return Uint8List.fromList(mac.bytes);
    }

    final sas = (await _sha256.hash([
      ...utf8.encode('settleup-sas'),
      ...transcript,
    ]))
        .bytes;
    final code = ByteData.sublistView(Uint8List.fromList(sas)).getUint32(0) %
        1000000;

    final fingerprint = (await _sha256.hash(okm)).bytes;

    return HandshakeKeys._(
      proto: proto,
      sharedGroups: List.unmodifiable(shared),
      maxFrame: min(localMaxFrame, peer.maxFrame),
      cipher: FrameCipher(
        sendKey: initiator ? kIR : kRI,
        receiveKey: initiator ? kRI : kIR,
      ),
      myMac: await authMac(initiator ? 'I' : 'R'),
      expectedPeerMac: await authMac(initiator ? 'R' : 'I'),
      verificationCode: code.toString().padLeft(6, '0'),
      transcript: transcript,
      keyFingerprint: _hex(fingerprint),
    );
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Everything the handshake produced.
final class HandshakeKeys {
  HandshakeKeys._({
    required this.proto,
    required this.sharedGroups,
    required this.maxFrame,
    required this.cipher,
    required this.myMac,
    required this._expectedPeerMac,
    required this.verificationCode,
    required this.transcript,
    required this.keyFingerprint,
  });

  final int proto;

  /// S: shared groups, sorted by id.
  final List<GroupId> sharedGroups;

  /// min(local, peer) max frame size.
  final int maxFrame;
  final FrameCipher cipher;

  /// Our AUTH mac.
  final Uint8List myMac;
  final Uint8List _expectedPeerMac;

  /// 6 digits, identical on both phones.
  final String verificationCode;
  final Uint8List transcript;

  /// SHA-256 of all derived key material, so tests can compare the two
  /// sides without the keys leaving this class.
  @visibleForTesting
  final String keyFingerprint;

  /// Constant-time check of the peer's AUTH mac.
  bool verifyPeerMac(List<int> mac) => constantTimeEquals(mac, _expectedPeerMac);
}

/// [name] as HELLO carries it: at most [kMaxDeviceNameLength] UTF-16 units
/// (what the peer accepts), cut on a character boundary so a letter outside
/// the BMP or a cluster is never split (DATA-R4-03). A split surrogate pair
/// would reach the peer as U+FFFD.
String helloDeviceName(String name) {
  if (name.length <= kMaxDeviceNameLength) return name;
  final out = StringBuffer();
  for (final ch in name.characters) {
    if (out.length + ch.length > kMaxDeviceNameLength) break;
    out.write(ch);
  }
  return out.toString();
}
