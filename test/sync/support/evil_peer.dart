// A hand-driven protocol peer for adversarial tests: it runs the real
// handshake with the keys it is given, then sends whatever frames the test
// wants, sealed with the real session keys.
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/sync/crypto/handshake.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/transport/transport.dart';

final class EvilPeer {
  EvilPeer(this.channel, {required this.initiator}) {
    _sub = channel.frames.listen(
      (f) {
        if (_waiting.isNotEmpty) {
          _waiting.removeFirst().complete(f);
        } else {
          _inbox.add(f);
        }
      },
      onDone: () {
        closed = true;
        for (final w in _waiting) {
          w.completeError(StateError('closed'));
        }
        _waiting.clear();
      },
      onError: (Object _) {},
    );
  }

  final FrameChannel channel;
  final bool initiator;
  final Queue<Uint8List> _inbox = Queue();
  final Queue<Completer<Uint8List>> _waiting = Queue();
  late final StreamSubscription<Uint8List> _sub;
  bool closed = false;
  HandshakeKeys? keys;

  /// Every message received after the handshake (sealed ones opened).
  final List<SyncMessage> received = [];

  Future<Uint8List> nextFrame() {
    if (_inbox.isNotEmpty) return Future.value(_inbox.removeFirst());
    final c = Completer<Uint8List>();
    _waiting.add(c);
    return c.future;
  }

  /// Next message, opening sealed frames once keys exist.
  Future<SyncMessage> next() async {
    final f = await nextFrame();
    final SyncMessage m;
    if (f[0] == FrameKind.plain) {
      m = FrameCodec.decodePlainFrame(f);
    } else {
      m = FrameCodec.decodePlain(await keys!.cipher.open(f));
    }
    received.add(m);
    return m;
  }

  /// Runs HELLO + AUTH with [groupKeys]. Returns the keys.
  Future<HandshakeKeys> handshake(
    Map<GroupId, Uint8List> groupKeys, {
    String deviceId = 'eeeeeeee-0000-7000-8000-000000000001',
  }) async {
    final hs = await Handshake.start(
      initiator: initiator,
      groupKeys: groupKeys,
      deviceId: deviceId,
      deviceName: 'Mallory',
      maxFrame: channel.maxFrameBytes,
      transport: channel.kind,
    );
    await channel.send(hs.helloFrame);
    final peerFrame = await nextFrame();
    final peerHello = FrameCodec.decodePlainFrame(peerFrame) as HelloMessage;
    final k = await hs.onPeerHello(peerHello, peerFrame,
        localMaxFrame: channel.maxFrameBytes);
    keys = k;
    await channel.send(FrameCodec.plainFrame(AuthMessage(mac: k.myMac)));
    final auth = FrameCodec.decodePlainFrame(await nextFrame()) as AuthMessage;
    if (!k.verifyPeerMac(auth.mac)) throw StateError('peer AUTH bad');
    return k;
  }

  Future<void> sendSealed(SyncMessage m) async =>
      channel.send(await keys!.cipher.seal(FrameCodec.encodePlain(m)));

  Future<void> sendPlain(SyncMessage m) =>
      channel.send(FrameCodec.plainFrame(m));

  /// Reads messages until [test] matches one (or the channel closes).
  Future<SyncMessage?> until(bool Function(SyncMessage) test) async {
    while (true) {
      try {
        final m = await next();
        if (test(m)) return m;
      } on StateError {
        return null;
      }
    }
  }

  Future<void> close() async {
    await _sub.cancel();
    await channel.close();
  }
}

/// A VV message for [g] claiming nothing.
VvMessage emptyVv(GroupId g) => VvMessage(groupId: g, vv: VersionVector.empty);
